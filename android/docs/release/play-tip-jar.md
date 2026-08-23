# Google Play tip jar

The Android tip jar uses four consumable one-time products. Product IDs are permanent after creation, so create them exactly as listed.

| Product ID | Play Console name | Suggested base price |
|---|---|---:|
| `tip_coffee` | Coffee tip | $0.99 USD |
| `tip_generous_coffee` | Generous coffee tip | $2.99 USD |
| `tip_very_generous` | Very generous tip | $4.99 USD |
| `tip_extremely_generous` | Extremely generous tip | $9.99 USD |

For each product in Play Console:

1. Open **Monetize with Play → Products → One-time products**.
2. Create the product with the exact ID above.
3. Add one **Buy** purchase option, make it available in the app's countries, and set its price.
4. Activate the purchase option and product. Do not enable rentals, pre-orders, discounts, or multi-quantity purchasing.

To test:

1. Add the tester under **Settings → License testing**.
2. Upload a signed app bundle containing the billing integration to an internal test track.
3. Add the tester to that track and install Enve from its Play opt-in link using the tester's Google account.
4. Open **Settings → About & support → About Enve → Tip Jar**.
5. Complete each test purchase, then confirm the same product can be purchased again. Successful tips are consumed immediately.

The `.debug` application ID is `com.enve.app.debug`, so a locally installed debug APK cannot query products belonging to the production `com.enve.app` Play listing.
