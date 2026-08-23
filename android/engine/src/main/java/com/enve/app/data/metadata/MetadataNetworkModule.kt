package com.enve.app.data.metadata

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import javax.inject.Qualifier
import javax.inject.Singleton

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class ExternalMetadataHttpClient

@Module
@InstallIn(SingletonComponent::class)
object MetadataNetworkModule {
    @Provides
    @Singleton
    @ExternalMetadataHttpClient
    fun provideExternalMetadataClient(): OkHttpClient {
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
}
