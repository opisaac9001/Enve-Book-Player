package com.enve.app.di

import android.content.Context
import com.enve.app.auth.MtlsManager
import com.enve.core.data.local.ConnectionRegistry
import coil.ImageLoader
import coil.disk.DiskCache
import coil.memory.MemoryCache
import com.enve.core.auth.CredentialVault
import com.enve.engine.impl.BuildConfig
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.remote.auth.AuthInterceptor
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.DynamicUrlInterceptor
import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.remote.JsonSafetyInterceptor
import com.enve.core.data.remote.security.PrivateNetworkTrust
import com.enve.core.data.remote.auth.TokenRefreshAuthenticator
import com.enve.core.di.RefreshClient
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.Cache
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.inject.Singleton
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Provides
    @Singleton
    fun provideCredentialVault(@ApplicationContext context: Context): CredentialVault {
        return CredentialVault(context)
    }

    @Provides
    @Singleton
    fun providePreferencesManager(
        @ApplicationContext context: Context,
        vault: CredentialVault,
    ): PreferencesManager {
        return PreferencesManager(context, vault)
    }

    @Provides
    @Singleton
    @RefreshClient
    fun provideRefreshOkHttpClient(): OkHttpClient {

        val trustManager = PrivateNetworkTrust.buildTrustManager()
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(trustManager), SecureRandom())
        }

        return OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier(PrivateNetworkTrust.buildHostnameVerifier())
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideOkHttpClient(
        @ApplicationContext context: Context,
        authInterceptor: AuthInterceptor,
        dynamicUrlInterceptor: DynamicUrlInterceptor,
        jsonSafetyInterceptor: JsonSafetyInterceptor,
        tokenRefreshAuthenticator: TokenRefreshAuthenticator,
        mtlsManager: MtlsManager,
    ): OkHttpClient {

        val logging = HttpLoggingInterceptor { message ->
            android.util.Log.d("OkHttp", redactSensitiveHttpLogMessage(message))
        }.apply {
            level = if (BuildConfig.DEBUG) {
                HttpLoggingInterceptor.Level.HEADERS
            } else {
                HttpLoggingInterceptor.Level.BASIC
            }
            redactHeader("Authorization")
            redactHeader("Cookie")
            redactHeader("Set-Cookie")
            redactHeader("X-Plex-Token")
            redactHeader("X-Emby-Token")
        }

        val trustManager = PrivateNetworkTrust.buildTrustManager()

        val dynamicKeyManager = mtlsManager.buildKeyManager()

        val sslContext = SSLContext.getInstance("TLS").apply {
            init(
                arrayOf<KeyManager>(dynamicKeyManager),
                arrayOf<TrustManager>(trustManager),
                SecureRandom(),
            )
        }

        val responseCache = Cache(java.io.File(context.cacheDir, "okhttp"), 10L * 1024 * 1024)

        val baseExecutor = java.util.concurrent.Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "OkHttp Dispatcher").apply { isDaemon = false }
        }
        val dispatcher = okhttp3.Dispatcher(ConnectionScope.propagatingExecutor(baseExecutor))

        return OkHttpClient.Builder()
            .dispatcher(dispatcher)
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier(PrivateNetworkTrust.buildHostnameVerifier())
            .cache(responseCache)
            .addInterceptor(dynamicUrlInterceptor)
            .addInterceptor(authInterceptor)
            .addInterceptor(jsonSafetyInterceptor)
            .addInterceptor(logging)
            .authenticator(tokenRefreshAuthenticator)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    @PublicMetadataHttpClient
    fun providePublicMetadataHttpClient(): OkHttpClient {
        return OkHttpClient.Builder()
            .addInterceptor { chain ->
                val request = chain.request().newBuilder()
                    .header("User-Agent", "Enve/1.0 (Android)")
                    .header("Accept", "application/json")
                    .build()
                chain.proceed(request)
            }
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideRetrofit(okHttpClient: OkHttpClient): Retrofit {
        return Retrofit.Builder()
            .baseUrl("http://localhost/")
            .client(okHttpClient)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
    }

    @Provides
    @Singleton
    fun provideGrimmoryApi(retrofit: Retrofit): GrimmoryApi {
        return retrofit.create(GrimmoryApi::class.java)
    }

    @Provides
    @Singleton
    fun provideGrimmoryAppApi(retrofit: Retrofit): com.enve.app.data.remote.GrimmoryAppApi {
        return retrofit.create(com.enve.app.data.remote.GrimmoryAppApi::class.java)
    }

    @Provides
    @Singleton
    fun provideImageLoader(
        @ApplicationContext context: Context,
        okHttpClient: OkHttpClient,
        einkDetector: com.enve.app.eink.EinkDetector,
    ): ImageLoader {

        val einkDetected = runCatching { einkDetector.detect().isEink }.getOrDefault(false)
        return ImageLoader.Builder(context)
            .callFactory(okHttpClient)
            .respectCacheHeaders(false)
            .memoryCache {
                MemoryCache.Builder(context)
                    .maxSizePercent(0.25)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(context.cacheDir.resolve("image_cache"))
                    .maxSizePercent(0.05)
                    .build()
            }
            .crossfade(if (einkDetected) 0 else 200)
            .build()
    }

    @Provides
    @Singleton
    fun provideReaderDatabase(@ApplicationContext context: Context): com.enve.app.data.local.ReaderDatabase {
        return com.enve.app.data.local.ReaderDatabase.getInstance(context)
    }

    @Provides
    @Singleton
    fun provideBookCacheDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.BookCacheDao {
        return db.bookCacheDao()
    }

    @Provides
    @Singleton
    fun provideBookExtrasDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.BookExtrasDao {
        return db.bookExtrasDao()
    }

    @Provides
    @Singleton
    fun provideLibraryCacheDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.LibraryCacheDao {
        return db.libraryCacheDao()
    }

    @Provides
    @Singleton
    fun provideAnnotationDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.model.ReaderAnnotationDao {
        return db.annotationDao()
    }

    @Provides
    @Singleton
    fun providePendingProgressPushDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.PendingProgressPushDao {
        return db.pendingProgressPushDao()
    }

    @Provides
    @Singleton
    fun provideVocabEntryDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.model.VocabEntryDao {
        return db.vocabEntryDao()
    }

    @Provides
    @Singleton
    fun provideMatchedBookMetadataDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.app.data.metadata.MatchedBookMetadataDao {
        return db.matchedBookMetadataDao()
    }

    @Provides
    @Singleton
    fun provideLinkedBookPairDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.LinkedBookPairDao {
        return db.linkedBookPairDao()
    }

    @Provides
    @Singleton
    fun provideUserCollectionDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.UserCollectionDao {
        return db.userCollectionDao()
    }

    @Provides
    @Singleton
    fun provideBookMetadataOverrideDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.BookMetadataOverrideDao {
        return db.bookMetadataOverrideDao()
    }

    @Provides
    @Singleton
    fun provideCustomSmartCollectionDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.core.data.local.CustomSmartCollectionDao {
        return db.customSmartCollectionDao()
    }

    @Provides
    @Singleton
    fun provideStoryAlignJobDao(db: com.enve.app.data.local.ReaderDatabase): com.enve.app.storyalign.StoryAlignJobDao {
        return db.storyAlignJobDao()
    }
}
