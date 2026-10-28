# ProScaner - R8 keep rules (used only if minify is turned back on for release).
#
# Plugins built on package:jni (shared_preferences_android, path_provider_android)
# are called from Dart by exact Java class and method signatures. R8 must not
# rename those classes, or the Kotlin types that appear in their signatures.
# Without these rules the app shows a black screen at startup:
#   NoSuchMethodError: SharedPreferencesApiRegistrar.getAll(...Lkotlin/coroutines/Continuation;)
-keep class io.flutter.plugins.** { *; }
-keep class com.github.dart_lang.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$** { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.jvm.functions.** { *; }

# ProScaner's own Bluetooth Classic and Wi-Fi channels (ProScanerActivity)
-keep class com.obddoctor.obd_doctor.** { *; }
