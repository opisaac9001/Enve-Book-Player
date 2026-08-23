package com.enve.app.viewmodel

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class TipProduct(
    val productId: String,
    val title: String,
    val subtitle: String,
    val formattedPrice: String? = null,
)

data class TipJarNotice(
    val title: String,
    val message: String,
)

data class TipJarState(
    val products: List<TipProduct> = TIP_PRODUCTS,
    val isLoading: Boolean = true,
    val purchasingProductId: String? = null,
    val error: String? = null,
    val notice: TipJarNotice? = null,
)

private data class PurchasableTip(
    val productDetails: ProductDetails,
    val offerDetails: ProductDetails.OneTimePurchaseOfferDetails,
)

private val TIP_PRODUCTS = listOf(
    TipProduct("tip_coffee", "Coffee", "Buy me a coffee"),
    TipProduct("tip_generous_coffee", "Generous Coffee", "Buy me a fancy coffee"),
    TipProduct("tip_very_generous", "Very Generous", "Support development"),
    TipProduct("tip_extremely_generous", "Extremely Generous", "Amazing support!"),
)

private val TIP_PRODUCT_IDS = TIP_PRODUCTS.mapTo(hashSetOf()) { it.productId }

@HiltViewModel
class TipJarViewModel @Inject constructor(
    @ApplicationContext context: Context,
) : ViewModel(), PurchasesUpdatedListener {
    private val _state = MutableStateFlow(TipJarState())
    val state: StateFlow<TipJarState> = _state.asStateFlow()

    private val purchasableTips = mutableMapOf<String, PurchasableTip>()
    private val consumingTokens = mutableSetOf<String>()
    private var isConnecting = false
    private var loadingTimeout: Job? = null

    private val billingClient = BillingClient.newBuilder(context)
        .setListener(this)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder()
                .enableOneTimeProducts()
                .build(),
        )
        .build()

    init {
        connect()
    }

    fun purchase(activity: Activity, productId: String) {
        val purchasable = purchasableTips[productId] ?: return
        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(purchasable.productDetails)
            .apply {
                purchasable.offerDetails.offerToken?.let(::setOfferToken)
            }
            .build()
        val result = billingClient.launchBillingFlow(
            activity,
            BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(productParams))
                .build(),
        )

        if (result.responseCode == BillingClient.BillingResponseCode.OK) {
            _state.update { it.copy(purchasingProductId = productId, error = null) }
        } else {
            handleBillingError(result, "Google Play couldn't start this purchase.")
        }
    }

    fun retry() {
        _state.update { it.copy(isLoading = true, error = null) }
        if (billingClient.isReady) {
            loadProducts()
            queryOutstandingPurchases()
        } else {
            connect()
        }
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    override fun onPurchasesUpdated(
        billingResult: BillingResult,
        purchases: MutableList<Purchase>?,
    ) {
        when (billingResult.responseCode) {
            BillingClient.BillingResponseCode.OK -> processPurchases(purchases.orEmpty())
            BillingClient.BillingResponseCode.USER_CANCELED -> {
                _state.update { it.copy(purchasingProductId = null) }
            }
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> queryOutstandingPurchases()
            else -> handleBillingError(billingResult, "Google Play couldn't complete this purchase.")
        }
    }

    override fun onCleared() {
        billingClient.endConnection()
    }

    private fun connect() {
        if (isConnecting || billingClient.isReady) return
        isConnecting = true
        ensureLoadingTimeout()
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(billingResult: BillingResult) {
                isConnecting = false
                if (billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                    loadProducts()
                    queryOutstandingPurchases()
                } else {
                    handleBillingError(billingResult, "Tips aren't available through Google Play right now.")
                }
            }

            override fun onBillingServiceDisconnected() {
                isConnecting = false
                loadingTimeout?.cancel()
                _state.update {
                    it.copy(
                        isLoading = false,
                        purchasingProductId = null,
                        error = "The Google Play billing service disconnected. Try again.",
                    )
                }
            }
        })
    }

    private fun loadProducts() {
        ensureLoadingTimeout()
        _state.update { it.copy(isLoading = true, error = null) }
        val products = TIP_PRODUCT_IDS.map { productId ->
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(productId)
                .setProductType(BillingClient.ProductType.INAPP)
                .build()
        }
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(products)
            .build()

        billingClient.queryProductDetailsAsync(params) { billingResult, queryResult ->
            loadingTimeout?.cancel()
            if (billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                handleBillingError(billingResult, "Google Play couldn't load the tip options.")
                return@queryProductDetailsAsync
            }

            purchasableTips.clear()
            queryResult.productDetailsList.forEach { productDetails ->
                val offer = productDetails.oneTimePurchaseOfferDetailsList
                    ?.firstOrNull { it.rentalDetails == null && it.preorderDetails == null }
                    ?: productDetails.oneTimePurchaseOfferDetails
                    ?: return@forEach
                purchasableTips[productDetails.productId] = PurchasableTip(productDetails, offer)
            }

            val productsWithPrices = TIP_PRODUCTS.map { product ->
                product.copy(
                    formattedPrice = purchasableTips[product.productId]
                        ?.offerDetails
                        ?.formattedPrice,
                )
            }
            val error = when {
                purchasableTips.isEmpty() ->
                    "Tip options aren't available. Install a Play testing or production build and check that the products are active."
                purchasableTips.size < TIP_PRODUCTS.size ->
                    "Some tip options aren't available through Google Play right now."
                else -> null
            }
            _state.update {
                it.copy(
                    products = productsWithPrices,
                    isLoading = false,
                    error = error,
                )
            }
        }
    }

    private fun queryOutstandingPurchases() {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
        billingClient.queryPurchasesAsync(params) { billingResult, purchases ->
            if (billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                processPurchases(purchases)
            } else {
                Log.w(TAG, "Unable to query purchases: ${billingResult.responseCode} ${billingResult.debugMessage}")
            }
        }
    }

    private fun processPurchases(purchases: List<Purchase>) {
        purchases
            .filter { purchase -> purchase.products.any(TIP_PRODUCT_IDS::contains) }
            .forEach { purchase ->
                when (purchase.purchaseState) {
                    Purchase.PurchaseState.PURCHASED -> consume(purchase)
                    Purchase.PurchaseState.PENDING -> {
                        _state.update {
                            it.copy(
                                purchasingProductId = null,
                                notice = TipJarNotice(
                                    title = "Payment pending",
                                    message = "Thank you. Your tip will complete after Google Play confirms the payment.",
                                ),
                            )
                        }
                    }
                }
            }
    }

    private fun consume(purchase: Purchase) {
        if (!consumingTokens.add(purchase.purchaseToken)) return
        val params = ConsumeParams.newBuilder()
            .setPurchaseToken(purchase.purchaseToken)
            .build()
        billingClient.consumeAsync(params) { billingResult, purchaseToken ->
            consumingTokens.remove(purchaseToken)
            if (billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                _state.update {
                    it.copy(
                        purchasingProductId = null,
                        error = null,
                        notice = TipJarNotice(
                            title = "Thank you!",
                            message = "Your support means a lot and helps keep Enve growing.",
                        ),
                    )
                }
            } else {
                handleBillingError(
                    billingResult,
                    "Your payment completed, but Google Play hasn't finalized the tip yet. It will be retried automatically.",
                )
            }
        }
    }

    private fun handleBillingError(result: BillingResult, userMessage: String) {
        loadingTimeout?.cancel()
        Log.w(TAG, "Billing error: ${result.responseCode} ${result.debugMessage}")
        _state.update {
            it.copy(
                isLoading = false,
                purchasingProductId = null,
                error = userMessage,
            )
        }
    }

    private fun ensureLoadingTimeout() {
        if (loadingTimeout?.isActive == true) return
        loadingTimeout = viewModelScope.launch {
            delay(15_000)
            isConnecting = false
            _state.update {
                it.copy(
                    isLoading = false,
                    purchasingProductId = null,
                    error = "Google Play is taking too long to respond. Check your connection and try again.",
                )
            }
        }
    }

    private companion object {
        const val TAG = "TipJarViewModel"
    }
}
