/* @ts-self-types="./phonon_tts.d.ts" */

/**
 * A loaded model, on the CPU.
 *
 * The state sits behind an `Rc<RefCell<Option<_>>>` because `generation_step` returns a
 * promise and a `RefCell` borrow may not be held across one: the step takes the state out for
 * its duration and puts it back after. A call that arrives meanwhile finds it missing and is
 * refused, so calls must not overlap; `phonon-tts`'s worker awaits each one. The exception
 * is `stop_generation`, which the step applies when it puts the state back.
 */
export class Model {
    static __wrap(ptr) {
        const obj = Object.create(Model.prototype);
        obj.__wbg_ptr = ptr;
        ModelFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        ModelFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_model_free(ptr, 0);
    }
    /**
     * Registers a voice from a safetensors file and returns its index for
     * `start_generation`. Either a precomputed KV cache (`embeddings_v2/`) or a voice
     * embedding (`emb`, `audio_prompt` or `speaker_wavs`), told apart by tensor name.
     * @param {Uint8Array} voice
     * @returns {number}
     */
    add_voice(voice) {
        const ptr0 = passArray8ToWasm0(voice, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.model_add_voice(this.__wbg_ptr, ptr0, len0);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return ret[0] >>> 0;
    }
    /**
     * `"cpu"`: where this model runs.
     * @returns {string}
     */
    device() {
        let deferred2_0;
        let deferred2_1;
        try {
            const ret = wasm.model_device(this.__wbg_ptr);
            var ptr1 = ret[0];
            var len1 = ret[1];
            if (ret[3]) {
                ptr1 = 0; len1 = 0;
                throw takeFromExternrefTable0(ret[2]);
            }
            deferred2_0 = ptr1;
            deferred2_1 = len1;
            return getStringFromWasm0(ptr1, len1);
        } finally {
            wasm.__wbindgen_free(deferred2_0, deferred2_1, 1);
        }
    }
    /**
     * Kept for callers written when this module also ran on WebGPU, where a voice's prompt
     * was only recorded until flushed. The CPU has nothing queued: resolves at once.
     * @returns {Promise<any>}
     */
    flush() {
        const ret = wasm.model_flush(this.__wbg_ptr);
        return ret;
    }
    /**
     * Samples in one 80 ms frame: `generation_step` returns whole frames.
     * @returns {number}
     */
    frame_size() {
        const ret = wasm.model_frame_size(this.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return ret[0] >>> 0;
    }
    /**
     * Generates and decodes the next frame of the current chunk: a promise of mono PCM at
     * `sample_rate`, one `frame_size`-sample frame, or of `undefined` when the chunk is
     * finished.
     * @returns {Promise<any>}
     */
    generation_step() {
        const ret = wasm.model_generation_step(this.__wbg_ptr);
        return ret;
    }
    /**
     * The languages the model was trained for, as listed in its config.
     * @returns {string[]}
     */
    languages() {
        const ret = wasm.model_languages(this.__wbg_ptr);
        if (ret[3]) {
            throw takeFromExternrefTable0(ret[2]);
        }
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Loads a model. `model_weights` is a safetensors or GGUF checkpoint, `tokenizer_json`
     * the contents of the `tokenizer.json` for its vocabulary, and `config_json` its
     * `config.json`. All three are required.
     *
     * One thing a config cannot ask this build for: classifier-free guidance. Guidance is a
     * caller's option in `ptts::synth` (`SpeechOptions::cfg_coef`), not a field of the
     * config, and the browser build never turns it on, so `cfg_null_audio_empty` is inert.
     * A config with baked-in `voices` is refused: voices here come from files. Everything
     * else -- the flow LM and Mimi shapes, `lsd_decode_steps`, `eos_threshold`, `model_id`,
     * `speaker_mimi`, `conditioners` -- is honored.
     *
     * `quant` is `"f32"` or `"q8"`.
     *
     * `lang` is required: the language text is normalized as before it is
     * tokenized, one of `"en"`, `"fr"`, `"de"`, `"es"`, `"pt"`, `"ar"`, `"hi"`,
     * `"ko"`, `"pl"`, `"sv"`, `"fi"`, `"no"`, `"it"`, `"nl"`, `"ja"`, `"zh"`,
     * `"da"`, `"tr"`, or `"none"`
     * to hand text to the tokenizer as written. The spoken forms of `@`, `+`
     * and `=` differ per language, so there is nothing safe to default to.
     *
     * `rewrites` is optional and picks which word rewrites run on the
     * normalized text: `"default"` (numbers, currency, dashed-digits, emails,
     * urls, abbreviations, elongations), `"all"` (those and phones, times,
     * dates), `"none"`, or a comma-separated list of rule names. The rules
     * only read `"en"`, `"fr"`, `"de"`, `"es"` and `"pt"`.
     *
     * `conditions` is optional and sets the config's conditioners, each as `"NAME=VALUE"`,
     * e.g. `["duration_delta=0.5"]`. Those left out take their defaults.
     *
     * `device` must be `"cpu"`. WebGPU is not in this module: `phonon-tts` runs its own
     * engine for it, with a [`Preparer`] for the text and the voices.
     * @param {Uint8Array} model_weights
     * @param {Uint8Array} tokenizer_json
     * @param {Uint8Array} config_json
     * @param {string} quant
     * @param {string} lang
     * @param {string | null | undefined} rewrites
     * @param {string[] | null | undefined} conditions
     * @param {string} device
     * @returns {Promise<Model>}
     */
    static load(model_weights, tokenizer_json, config_json, quant, lang, rewrites, conditions, device) {
        const ptr0 = passArray8ToWasm0(model_weights, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(tokenizer_json, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(config_json, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(quant, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        const ptr4 = passStringToWasm0(lang, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len4 = WASM_VECTOR_LEN;
        var ptr5 = isLikeNone(rewrites) ? 0 : passStringToWasm0(rewrites, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len5 = WASM_VECTOR_LEN;
        var ptr6 = isLikeNone(conditions) ? 0 : passArrayJsValueToWasm0(conditions, wasm.__wbindgen_malloc);
        var len6 = WASM_VECTOR_LEN;
        const ptr7 = passStringToWasm0(device, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len7 = WASM_VECTOR_LEN;
        const ret = wasm.model_load(ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, ptr4, len4, ptr5, len5, ptr6, len6, ptr7, len7);
        return ret;
    }
    /**
     * Prompts the model with the next chunk's text and returns its token count, or
     * `undefined` once every chunk has been generated.
     * @returns {number | undefined}
     */
    next_chunk() {
        const ret = wasm.model_next_chunk(this.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return ret[0] === Number.MAX_SAFE_INTEGER ? undefined : ret[0];
    }
    /**
     * @returns {number}
     */
    sample_rate() {
        const ret = wasm.model_sample_rate(this.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return ret[0] >>> 0;
    }
    /**
     * Normalizes `text`, splits it into sentence-aligned chunks and tokenizes them. Returns
     * the number of chunks. Runs no model: call `next_chunk` to start the first one.
     * @param {number} voice_index
     * @param {string} text
     * @param {number} temperature
     * @param {bigint} seed
     * @returns {number}
     */
    start_generation(voice_index, text, temperature, seed) {
        const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.model_start_generation(this.__wbg_ptr, voice_index, ptr0, len0, temperature, seed);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return ret[0] >>> 0;
    }
    /**
     * Drops the generation in progress, if any. Called while a `generation_step` is pending,
     * it takes effect when that step returns: the step still delivers its frame, and the
     * next one reports the end.
     */
    stop_generation() {
        wasm.model_stop_generation(this.__wbg_ptr);
    }
}
if (Symbol.dispose) Model.prototype[Symbol.dispose] = Model.prototype.free;

/**
 * The parts of a checkpoint the WebGPU engine needs from Rust, without the model itself: the
 * tokenizer and the text normalization ([`plan::chunks`], as every other frontend splits
 * text), the voice files, and the sum of the config's conditioners.
 *
 * Its tensors are the few the conditioners and the speaker projection need, which the caller
 * takes out of the checkpoint (`flow_lm.condition_provider.conditioners.*` in the GGUF, under
 * their GGUF names, as a safetensors file). The transformer and Mimi weights never come here.
 */
export class Preparer {
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        PreparerFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_preparer_free(ptr, 0);
    }
    /**
     * The vector every frame's input adds: the conditioners at their values, `d_model` long
     * (zeros for a checkpoint without conditioners).
     * @returns {Float32Array}
     */
    conditions() {
        const ret = wasm.preparer_conditions(this.__wbg_ptr);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Samples in one 80 ms frame.
     * @returns {number}
     */
    frame_size() {
        const ret = wasm.preparer_frame_size(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * The languages the model was trained for, as listed in its config.
     * @returns {string[]}
     */
    languages() {
        const ret = wasm.preparer_languages(this.__wbg_ptr);
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * `tokenizer_json`, `config_json`, `lang`, `rewrites` and `conditions` as for
     * [`Model::load`]; `tensors` a safetensors file with the conditioner tensors.
     * @param {Uint8Array} tokenizer_json
     * @param {Uint8Array} config_json
     * @param {Uint8Array} tensors
     * @param {string} lang
     * @param {string | null} [rewrites]
     * @param {string[] | null} [conditions]
     */
    constructor(tokenizer_json, config_json, tensors, lang, rewrites, conditions) {
        const ptr0 = passArray8ToWasm0(tokenizer_json, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(config_json, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArray8ToWasm0(tensors, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(lang, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        var ptr4 = isLikeNone(rewrites) ? 0 : passStringToWasm0(rewrites, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len4 = WASM_VECTOR_LEN;
        var ptr5 = isLikeNone(conditions) ? 0 : passArrayJsValueToWasm0(conditions, wasm.__wbindgen_malloc);
        var len5 = WASM_VECTOR_LEN;
        const ret = wasm.preparer_new(ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, ptr4, len4, ptr5, len5);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        this.__wbg_ptr = ret[0];
        PreparerFinalization.register(this, this.__wbg_ptr, this);
        return this;
    }
    /**
     * `text` as the model is prompted with it: an array of chunks, each
     * `{ tokens: Uint32Array, framesAfterEos, frameBudget }`.
     * @param {string} text
     * @returns {Array<any>}
     */
    plan(text) {
        const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.preparer_plan(this.__wbg_ptr, ptr0, len0);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return takeFromExternrefTable0(ret[0]);
    }
    /**
     * @returns {number}
     */
    sample_rate() {
        const ret = wasm.preparer_sample_rate(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * A voice file's prompt: `{ kind: 'rows', frames, rows }`, the rows the flow LM is
     * prompted with (`[frames, d_model]`, for an `emb` voice or `speaker_wavs` latents through
     * the speaker projection), or `{ kind: 'kv', frames, k, v }` for a voice stored as the KV
     * cache (`embeddings_v2/`): one `[frames, heads * head_dim]` array per layer in `k` and `v`.
     * @param {Uint8Array} bytes
     * @returns {object}
     */
    voice(bytes) {
        const ptr0 = passArray8ToWasm0(bytes, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.preparer_voice(this.__wbg_ptr, ptr0, len0);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return takeFromExternrefTable0(ret[0]);
    }
}
if (Symbol.dispose) Preparer.prototype[Symbol.dispose] = Preparer.prototype.free;

/**
 * CPU SIMD features the wasm module was compiled with. The relevant one
 * for browser builds is `simd128`; `avx`/`neon`/`f16c` are reported for
 * completeness so it's clear which native-target builds enabled them.
 * @returns {object}
 */
export function cpu_features() {
    const ret = wasm.cpu_features();
    return ret;
}
function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg_Error_3639a60ed15f87e7: function(arg0, arg1) {
            const ret = Error(getStringFromWasm0(arg0, arg1));
            return ret;
        },
        __wbg___wbindgen_is_function_2f0fd7ceb86e64c5: function(arg0) {
            const ret = typeof(arg0) === 'function';
            return ret;
        },
        __wbg___wbindgen_is_undefined_244a92c34d3b6ec0: function(arg0) {
            const ret = arg0 === undefined;
            return ret;
        },
        __wbg___wbindgen_string_get_965592073e5d848c: function(arg0, arg1) {
            const obj = arg1;
            const ret = typeof(obj) === 'string' ? obj : undefined;
            var ptr1 = isLikeNone(ret) ? 0 : passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg___wbindgen_throw_9c75d47bf9e7731e: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbg__wbg_cb_unref_158e43e869788cdc: function(arg0) {
            arg0._wbg_cb_unref();
        },
        __wbg_call_a41d6421b30a32c5: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = arg0.call(arg1, arg2);
            return ret;
        }, arguments); },
        __wbg_getRandomValues_3f44b700395062e5: function() { return handleError(function (arg0, arg1) {
            globalThis.crypto.getRandomValues(getArrayU8FromWasm0(arg0, arg1));
        }, arguments); },
        __wbg_log_2a91de5c5ae34c4a: function(arg0, arg1) {
            console.log(getStringFromWasm0(arg0, arg1));
        },
        __wbg_model_new: function(arg0) {
            const ret = Model.__wrap(arg0);
            return ret;
        },
        __wbg_new_2fad8ca02fd00684: function() {
            const ret = new Object();
            return ret;
        },
        __wbg_new_3baa8d9866155c79: function() {
            const ret = new Array();
            return ret;
        },
        __wbg_new_from_slice_0f99167330d1143b: function(arg0, arg1) {
            const ret = new Float32Array(getArrayF32FromWasm0(arg0, arg1));
            return ret;
        },
        __wbg_new_from_slice_823acd363b3844cf: function(arg0, arg1) {
            const ret = new Uint32Array(getArrayU32FromWasm0(arg0, arg1));
            return ret;
        },
        __wbg_new_typed_1137602701dc87d4: function(arg0, arg1) {
            try {
                var state0 = {a: arg0, b: arg1};
                var cb0 = (arg0, arg1) => {
                    const a = state0.a;
                    state0.a = 0;
                    try {
                        return wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined_______true_(a, state0.b, arg0, arg1);
                    } finally {
                        state0.a = a;
                    }
                };
                const ret = new Promise(cb0);
                return ret;
            } finally {
                state0.a = 0;
            }
        },
        __wbg_push_60a5366c0bb22a7d: function(arg0, arg1) {
            const ret = arg0.push(arg1);
            return ret;
        },
        __wbg_queueMicrotask_40ac6ffc2848ba77: function(arg0) {
            queueMicrotask(arg0);
        },
        __wbg_queueMicrotask_74d092439f6494c1: function(arg0) {
            const ret = arg0.queueMicrotask;
            return ret;
        },
        __wbg_resolve_9feb5d906ca62419: function(arg0) {
            const ret = Promise.resolve(arg0);
            return ret;
        },
        __wbg_set_5337f8ac82364a3f: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = Reflect.set(arg0, arg1, arg2);
            return ret;
        }, arguments); },
        __wbg_static_accessor_GLOBAL_THIS_1c7f1bd6c6941fdb: function() {
            const ret = typeof globalThis === 'undefined' ? null : globalThis;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_GLOBAL_e039bc914f83e74e: function() {
            const ret = typeof global === 'undefined' ? null : global;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_SELF_8bf8c48c28420ad5: function() {
            const ret = typeof self === 'undefined' ? null : self;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_WINDOW_6aeee9b51652ee0f: function() {
            const ret = typeof window === 'undefined' ? null : window;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_then_20a157d939b514f5: function(arg0, arg1) {
            const ret = arg0.then(arg1);
            return ret;
        },
        __wbindgen_cast_0000000000000001: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [Externref], shim_idx: 351, ret: Result(Unit), inner_ret: Some(Result(Unit)) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___wasm_bindgen_f59f3b34b769d362___JsValue__core_37ee0ce0c4cd57d5___result__Result_____wasm_bindgen_f59f3b34b769d362___JsError___true_);
            return ret;
        },
        __wbindgen_cast_0000000000000002: function(arg0) {
            // Cast intrinsic for `F64 -> Externref`.
            const ret = arg0;
            return ret;
        },
        __wbindgen_cast_0000000000000003: function(arg0, arg1) {
            // Cast intrinsic for `Ref(String) -> Externref`.
            const ret = getStringFromWasm0(arg0, arg1);
            return ret;
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        },
    };
    return {
        __proto__: null,
        "./phonon_tts_bg.js": import0,
    };
}

function wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___wasm_bindgen_f59f3b34b769d362___JsValue__core_37ee0ce0c4cd57d5___result__Result_____wasm_bindgen_f59f3b34b769d362___JsError___true_(arg0, arg1, arg2) {
    const ret = wasm.wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___wasm_bindgen_f59f3b34b769d362___JsValue__core_37ee0ce0c4cd57d5___result__Result_____wasm_bindgen_f59f3b34b769d362___JsError___true_(arg0, arg1, arg2);
    if (ret[1]) {
        throw takeFromExternrefTable0(ret[0]);
    }
}

function wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined_______true_(arg0, arg1, arg2, arg3) {
    wasm.wasm_bindgen_f59f3b34b769d362___convert__closures_____invoke___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined___js_sys_ee9836ddb2bdf100___Function_fn_wasm_bindgen_f59f3b34b769d362___JsValue_____wasm_bindgen_f59f3b34b769d362___sys__Undefined_______true_(arg0, arg1, arg2, arg3);
}

const ModelFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_model_free(ptr, 1));
const PreparerFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_preparer_free(ptr, 1));

function addToExternrefTable0(obj) {
    const idx = wasm.__externref_table_alloc();
    wasm.__wbindgen_externrefs.set(idx, obj);
    return idx;
}

const CLOSURE_DTORS = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(state => wasm.__wbindgen_destroy_closure(state.a, state.b));

function getArrayF32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayJsValueFromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    const mem = getDataViewMemory0();
    const result = [];
    for (let i = ptr; i < ptr + 4 * len; i += 4) {
        result.push(wasm.__wbindgen_externrefs.get(mem.getUint32(i, true)));
    }
    wasm.__externref_drop_slice(ptr, len);
    return result;
}

function getArrayU32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayU8FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}

let cachedDataViewMemory0 = null;
function getDataViewMemory0() {
    if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || (cachedDataViewMemory0.buffer.detached === undefined && cachedDataViewMemory0.buffer !== wasm.memory.buffer)) {
        cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
    }
    return cachedDataViewMemory0;
}

let cachedFloat32ArrayMemory0 = null;
function getFloat32ArrayMemory0() {
    if (cachedFloat32ArrayMemory0 === null || cachedFloat32ArrayMemory0.byteLength === 0) {
        cachedFloat32ArrayMemory0 = new Float32Array(wasm.memory.buffer);
    }
    return cachedFloat32ArrayMemory0;
}

function getStringFromWasm0(ptr, len) {
    return decodeText(ptr >>> 0, len);
}

let cachedUint32ArrayMemory0 = null;
function getUint32ArrayMemory0() {
    if (cachedUint32ArrayMemory0 === null || cachedUint32ArrayMemory0.byteLength === 0) {
        cachedUint32ArrayMemory0 = new Uint32Array(wasm.memory.buffer);
    }
    return cachedUint32ArrayMemory0;
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function handleError(f, args) {
    try {
        return f.apply(this, args);
    } catch (e) {
        const idx = addToExternrefTable0(e);
        wasm.__wbindgen_exn_store(idx);
    }
}

function isLikeNone(x) {
    return x === undefined || x === null;
}

function makeMutClosure(arg0, arg1, f) {
    const state = { a: arg0, b: arg1, cnt: 1 };
    const real = (...args) => {

        // First up with a closure we increment the internal reference
        // count. This ensures that the Rust closure environment won't
        // be deallocated while we're invoking it.
        state.cnt++;
        const a = state.a;
        state.a = 0;
        try {
            return f(a, state.b, ...args);
        } finally {
            state.a = a;
            real._wbg_cb_unref();
        }
    };
    real._wbg_cb_unref = () => {
        if (--state.cnt === 0) {
            wasm.__wbindgen_destroy_closure(state.a, state.b);
            state.a = 0;
            CLOSURE_DTORS.unregister(state);
        }
    };
    CLOSURE_DTORS.register(real, state, state);
    return real;
}

function passArray8ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 1, 1) >>> 0;
    getUint8ArrayMemory0().set(arg, ptr / 1);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passArrayJsValueToWasm0(array, malloc) {
    const ptr = malloc(array.length * 4, 4) >>> 0;
    for (let i = 0; i < array.length; i++) {
        const add = addToExternrefTable0(array[i]);
        getDataViewMemory0().setUint32(ptr + 4 * i, add, true);
    }
    WASM_VECTOR_LEN = array.length;
    return ptr;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

function takeFromExternrefTable0(idx) {
    const value = wasm.__wbindgen_externrefs.get(idx);
    wasm.__externref_table_dealloc(idx);
    return value;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(ptr, len) {
    numBytesDecoded += len;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
        cachedTextDecoder.decode();
        numBytesDecoded = len;
    }
    return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasmInstance, wasm;
function __wbg_finalize_init(instance, module) {
    wasmInstance = instance;
    wasm = instance.exports;
    wasmModule = module;
    cachedDataViewMemory0 = null;
    cachedFloat32ArrayMemory0 = null;
    cachedUint32ArrayMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = module.ok && expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;


    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('phonon_tts_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
