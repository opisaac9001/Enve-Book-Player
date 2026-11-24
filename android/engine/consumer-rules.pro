-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class com.enve.app.readium.narrator.** {
    java.lang.Integer invoke(float[]);
}
-keep class com.google.ai.edge.litertlm.** { *; }
-keep class com.enve.app.document.NativeKindleEpubConverter$ParsedKindle* {
    <init>(...);
}
