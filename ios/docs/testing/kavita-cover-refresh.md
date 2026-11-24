# Kavita cover selection and refresh

Enve imports Kavita chapters as individual books/issues. Kavita stores series, volume, and chapter artwork independently; choosing a series cover does not replace every chapter's cover.

The provider maps artwork as follows:

| Item | Artwork endpoint |
| --- | --- |
| A series with one chapter and a locked custom series cover | `image/series-cover` |
| A volume containing one chapter | `image/volume-cover` |
| An issue in a volume with multiple chapters | `image/chapter-cover` |

This preserves distinct issue artwork in a multi-issue series. Separate series-level artwork on grouped series cards is not implemented by this change. Enve does not extract an archive's first image to replace the remote cover during download.

Volume and chapter cover URLs include the server's `lastModifiedUtc`, including fractional seconds. For a one-chapter volume, the later volume/chapter timestamp wins. Custom series covers have no modification date in the series DTO, so they revalidate after catalog refresh; servers that omit modification dates do the same. This uses metadata already fetched for the catalog, without another request per book. Catalog mapping revision 3 triggers remapping of existing imports.

Persistent covers carry an `enveCoverRevision` sidecar with the entity, ID, and version only. A saved image must match the requested revision before it can satisfy a normal remote-cover load. File modification time alone cannot distinguish an old chapter cover from a newly selected volume cover. Failed remote requests can still display the last saved cover offline. Successful image fetches replace the saved image and revision. No credentials or server addresses are stored in the sidecar.

Image requests add the current API key as an `apiKey` query parameter, including for password/JWT connections, while preserving authentication headers. Keys are added at request time and are absent from catalog cover URLs. Requests bypass URLSession's local response cache; Enve's versioned image cache remains active.

Regression coverage lives in `KavitaProgressTransportTests` and `CoverCacheVersionTests`: endpoint selection, fractional timestamp invalidation, stable unchanged versions, issue identity, authentication, old-cover rejection, revision persistence, and replacement cleanup.

Protocol references: [Kavita API documentation](https://www.kavitareader.com/docs/api/), [image endpoints](https://github.com/Kareadita/Kavita/blob/develop/Kavita.Server/Controllers/ImageController.cs), [cover upload behavior](https://github.com/Kareadita/Kavita/blob/develop/Kavita.Server/Controllers/UploadController.cs), and [image API-key compatibility](https://github.com/Kareadita/Kavita/issues/4816). Local reference reviewed: Kavita `d77d956`.
