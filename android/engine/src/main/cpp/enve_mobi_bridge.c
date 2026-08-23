#include <android/log.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "index.h"
#include "mobi.h"
#include "util.h"

#define TAG "EnveMobi"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static jclass find_class(JNIEnv *env, const char *name) {
    jclass clazz = (*env)->FindClass(env, name);
    if (clazz == NULL) {
        (*env)->ExceptionClear(env);
        LOGE("Missing JNI class: %s", name);
    }
    return clazz;
}

static jstring new_string(JNIEnv *env, const char *value) {
    return value == NULL ? NULL : (*env)->NewStringUTF(env, value);
}

static jstring new_owned_string(JNIEnv *env, char *value) {
    if (value == NULL) {
        return NULL;
    }
    jstring result = (*env)->NewStringUTF(env, value);
    free(value);
    return result;
}

static jbyteArray new_byte_array(JNIEnv *env, const unsigned char *data, size_t size) {
    if (data == NULL || size > INT32_MAX) {
        return NULL;
    }
    jbyteArray array = (*env)->NewByteArray(env, (jsize) size);
    if (array != NULL && size > 0) {
        (*env)->SetByteArrayRegion(env, array, 0, (jsize) size, (const jbyte *) data);
    }
    return array;
}

static jbyteArray raw_html_bytes(JNIEnv *env, MOBIRawml *rawml) {
    size_t total = 0;
    for (MOBIPart *part = rawml->flow; part != NULL; part = part->next) {
        if (part->data != NULL) {
            total += part->size;
        }
    }

    if (total == 0 || total > INT32_MAX) {
        return NULL;
    }

    jbyteArray array = (*env)->NewByteArray(env, (jsize) total);
    if (array == NULL) {
        return NULL;
    }

    jsize offset = 0;
    for (MOBIPart *part = rawml->flow; part != NULL; part = part->next) {
        if (part->data != NULL && part->size > 0) {
            (*env)->SetByteArrayRegion(env, array, offset, (jsize) part->size, (const jbyte *) part->data);
            offset += (jsize) part->size;
        }
    }
    return array;
}

static const char *safe_extension(const MOBIFileMeta *meta) {
    return meta->extension[0] == '\0' ? "bin" : meta->extension;
}

static const char *safe_mime(const MOBIFileMeta *meta) {
    return meta->mime_type[0] == '\0' ? "application/octet-stream" : meta->mime_type;
}

JNIEXPORT jobject JNICALL
Java_com_enve_app_document_NativeKindleEpubConverter_parseKindleFile(
    JNIEnv *env,
    jobject thiz,
    jstring file_path
) {
    (void) thiz;

    const char *path = (*env)->GetStringUTFChars(env, file_path, 0);
    if (path == NULL) {
        return NULL;
    }

    MOBIData *mobi = mobi_init();
    if (mobi == NULL) {
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        LOGE("Could not open Kindle file: %s", path);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    MOBI_RET ret = mobi_load_file(mobi, file);
    fclose(file);
    if (ret != MOBI_SUCCESS) {
        LOGE("mobi_load_file failed: %d", ret);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    if (mobi->rh != NULL && mobi->rh->encryption_type != MOBI_ENCRYPTION_NONE) {
        LOGE("DRM-protected Kindle file rejected, encryption type: %u", mobi->rh->encryption_type);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    MOBIRawml *rawml = mobi_init_rawml(mobi);
    if (rawml == NULL) {
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    ret = mobi_parse_rawml_opt(rawml, mobi, true, false, true);
    if (ret != MOBI_SUCCESS) {
        LOGE("mobi_parse_rawml_opt failed: %d", ret);
        mobi_free_rawml(rawml);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    jclass book_class = find_class(env, "com/enve/app/document/NativeKindleEpubConverter$ParsedKindleBook");
    jclass resource_class = find_class(env, "com/enve/app/document/NativeKindleEpubConverter$ParsedKindleResource");
    jclass toc_class = find_class(env, "com/enve/app/document/NativeKindleEpubConverter$ParsedKindleTocEntry");
    if (book_class == NULL || resource_class == NULL || toc_class == NULL) {
        mobi_free_rawml(rawml);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    jmethodID book_ctor = (*env)->GetMethodID(
        env,
        book_class,
        "<init>",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;[B[Lcom/enve/app/document/NativeKindleEpubConverter$ParsedKindleResource;[Lcom/enve/app/document/NativeKindleEpubConverter$ParsedKindleTocEntry;I)V"
    );
    jmethodID resource_ctor = (*env)->GetMethodID(env, resource_class, "<init>", "(ILjava/lang/String;[BLjava/lang/String;)V");
    jmethodID toc_ctor = (*env)->GetMethodID(env, toc_class, "<init>", "(Ljava/lang/String;I)V");
    if (book_ctor == NULL || resource_ctor == NULL || toc_ctor == NULL) {
        mobi_free_rawml(rawml);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    jbyteArray html_array = raw_html_bytes(env, rawml);
    if (html_array == NULL) {
        mobi_free_rawml(rawml);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    jint cover_uid = -1;
    MOBIPdbRecord *cover_record = NULL;
    MOBIExthHeader *cover_exth = mobi_get_exthrecord_by_tag(mobi, EXTH_COVEROFFSET);
    if (cover_exth != NULL && mobi->mh != NULL && mobi->mh->image_index != NULL) {
        uint32_t cover_offset = mobi_decode_exthvalue(cover_exth->data, cover_exth->size);
        size_t first_image_sequence = *mobi->mh->image_index;
        cover_record = mobi_get_record_by_seqnumber(mobi, first_image_sequence + cover_offset);
        if (cover_record != NULL) {
            cover_uid = (jint) cover_record->uid;
        }
    }

    size_t binary_count = 0;
    bool cover_in_resources = false;
    for (MOBIPart *part = rawml->resources; part != NULL; part = part->next) {
        binary_count++;
        if (cover_record != NULL && part->uid == cover_record->uid) {
            cover_in_resources = true;
        }
    }

    size_t css_count = 0;
    size_t flow_index = 0;
    for (MOBIPart *part = rawml->flow; part != NULL; part = part->next, flow_index++) {
        if (mobi_determine_flowpart_type(rawml, flow_index) == T_CSS) {
            css_count++;
        }
    }

    size_t resource_count = binary_count + css_count + ((cover_record != NULL && !cover_in_resources) ? 1 : 0);
    jobjectArray resources = (*env)->NewObjectArray(env, (jsize) resource_count, resource_class, NULL);
    if (resources == NULL) {
        (*env)->DeleteLocalRef(env, html_array);
        mobi_free_rawml(rawml);
        mobi_free(mobi);
        (*env)->ReleaseStringUTFChars(env, file_path, path);
        return NULL;
    }

    jsize resource_index = 0;
    for (MOBIPart *part = rawml->resources; part != NULL; part = part->next) {
        if (part->data == NULL || part->size == 0) {
            continue;
        }
        MOBIFileMeta meta = mobi_get_filemeta_by_type(part->type);
        char filename[80];
        snprintf(filename, sizeof(filename), "res_%05u.%s", (unsigned int) part->uid, safe_extension(&meta));

        jstring path_string = new_string(env, filename);
        jstring mime_string = new_string(env, safe_mime(&meta));
        jbyteArray bytes = new_byte_array(env, part->data, part->size);
        jobject resource = (*env)->NewObject(env, resource_class, resource_ctor, (jint) part->uid, path_string, bytes, mime_string);
        (*env)->SetObjectArrayElement(env, resources, resource_index++, resource);

        (*env)->DeleteLocalRef(env, path_string);
        (*env)->DeleteLocalRef(env, mime_string);
        (*env)->DeleteLocalRef(env, bytes);
        (*env)->DeleteLocalRef(env, resource);
    }

    flow_index = 0;
    for (MOBIPart *part = rawml->flow; part != NULL; part = part->next, flow_index++) {
        if (mobi_determine_flowpart_type(rawml, flow_index) != T_CSS || part->data == NULL || part->size == 0) {
            continue;
        }
        MOBIFileMeta meta = mobi_get_filemeta_by_type(T_CSS);
        char filename[80];
        snprintf(filename, sizeof(filename), "flow_%05zu.css", flow_index);

        jstring path_string = new_string(env, filename);
        jstring mime_string = new_string(env, safe_mime(&meta));
        jbyteArray bytes = new_byte_array(env, part->data, part->size);
        jobject resource = (*env)->NewObject(env, resource_class, resource_ctor, (jint) (100000 + flow_index), path_string, bytes, mime_string);
        (*env)->SetObjectArrayElement(env, resources, resource_index++, resource);

        (*env)->DeleteLocalRef(env, path_string);
        (*env)->DeleteLocalRef(env, mime_string);
        (*env)->DeleteLocalRef(env, bytes);
        (*env)->DeleteLocalRef(env, resource);
    }

    if (cover_record != NULL && !cover_in_resources && cover_record->data != NULL && cover_record->size > 0) {
        MOBIFiletype cover_type = mobi_determine_resource_type(cover_record);
        MOBIFileMeta meta = mobi_get_filemeta_by_type(cover_type);
        char filename[80];
        snprintf(filename, sizeof(filename), "res_%05u.%s", (unsigned int) cover_record->uid, safe_extension(&meta));

        jstring path_string = new_string(env, filename);
        jstring mime_string = new_string(env, safe_mime(&meta));
        jbyteArray bytes = new_byte_array(env, cover_record->data, cover_record->size);
        jobject resource = (*env)->NewObject(env, resource_class, resource_ctor, (jint) cover_record->uid, path_string, bytes, mime_string);
        (*env)->SetObjectArrayElement(env, resources, resource_index, resource);

        (*env)->DeleteLocalRef(env, path_string);
        (*env)->DeleteLocalRef(env, mime_string);
        (*env)->DeleteLocalRef(env, bytes);
        (*env)->DeleteLocalRef(env, resource);
    }

    jobjectArray toc = NULL;
    MOBIIndx *toc_index = NULL;
    if (rawml->ncx != NULL && rawml->ncx->entries_count > 0) {
        toc_index = rawml->ncx;
    } else if (rawml->guide != NULL && rawml->guide->entries_count > 0) {
        toc_index = rawml->guide;
    }

    if (toc_index != NULL) {
        size_t valid_count = 0;
        for (size_t i = 0; i < toc_index->entries_count; i++) {
            uint32_t file_pos = 0;
            if (mobi_get_indxentry_tagvalue(&file_pos, &toc_index->entries[i], INDX_TAG_NCX_FILEPOS) == MOBI_SUCCESS) {
                valid_count++;
            }
        }
        toc = (*env)->NewObjectArray(env, (jsize) valid_count, toc_class, NULL);
        if (toc != NULL) {
            jsize toc_array_index = 0;
            for (size_t i = 0; i < toc_index->entries_count; i++) {
                MOBIIndexEntry entry = toc_index->entries[i];
                uint32_t file_pos = 0;
                if (mobi_get_indxentry_tagvalue(&file_pos, &entry, INDX_TAG_NCX_FILEPOS) != MOBI_SUCCESS) {
                    continue;
                }

                char *title_value = NULL;
                uint32_t cncx_offset = 0;
                if (toc_index->cncx_record != NULL &&
                    mobi_get_indxentry_tagvalue(&cncx_offset, &entry, INDX_TAG_NCX_TEXT_CNCX) == MOBI_SUCCESS) {
                    title_value = mobi_get_cncx_string(toc_index->cncx_record, cncx_offset);
                }

                jstring title_string = NULL;
                if (title_value != NULL && strlen(title_value) > 0) {
                    title_string = new_string(env, title_value);
                    free(title_value);
                } else {
                    title_string = new_string(env, entry.label);
                }

                jobject toc_entry = (*env)->NewObject(env, toc_class, toc_ctor, title_string, (jint) file_pos);
                (*env)->SetObjectArrayElement(env, toc, toc_array_index++, toc_entry);
                (*env)->DeleteLocalRef(env, title_string);
                (*env)->DeleteLocalRef(env, toc_entry);
            }
        }
    }

    jstring title = new_owned_string(env, mobi_meta_get_title(mobi));
    jstring author = new_owned_string(env, mobi_meta_get_author(mobi));
    jstring publisher = new_owned_string(env, mobi_meta_get_publisher(mobi));
    jstring language = new_owned_string(env, mobi_meta_get_language(mobi));

    jobject result = (*env)->NewObject(
        env,
        book_class,
        book_ctor,
        title,
        author,
        publisher,
        language,
        html_array,
        resources,
        toc,
        cover_uid
    );

    (*env)->DeleteLocalRef(env, title);
    (*env)->DeleteLocalRef(env, author);
    (*env)->DeleteLocalRef(env, publisher);
    (*env)->DeleteLocalRef(env, language);
    (*env)->DeleteLocalRef(env, html_array);
    (*env)->DeleteLocalRef(env, resources);
    if (toc != NULL) {
        (*env)->DeleteLocalRef(env, toc);
    }

    mobi_free_rawml(rawml);
    mobi_free(mobi);
    (*env)->ReleaseStringUTFChars(env, file_path, path);
    return result;
}