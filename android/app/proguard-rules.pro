# ML Kit Text Recognition Fix
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# Keep Vision Text classes
-keep class com.google.mlkit.vision.text.** { *; }

# Prevent stripping of ML Kit internal models
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }