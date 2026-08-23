package com.enve.app.readium

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser

@Singleton
class ReadiumManager @Inject constructor(@ApplicationContext context: Context) {

    private val appContext: Context = context.applicationContext

    private val httpClient = DefaultHttpClient()

    val assetRetriever = AssetRetriever(
        contentResolver = appContext.contentResolver,
        httpClient = httpClient,
    )

    val publicationOpener = PublicationOpener(
        publicationParser = DefaultPublicationParser(
            context = appContext,
            httpClient = httpClient,
            assetRetriever = assetRetriever,
            pdfFactory = null,
        ),
    )
}
