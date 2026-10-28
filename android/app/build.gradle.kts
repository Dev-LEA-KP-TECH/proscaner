import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------- ProScaner: แอปตัวจริง / ตัวทดสอบ ----------------
// แอปตัวจริง (com.proscaner.app ชื่อถาวร) สร้างเฉพาะเมื่อตั้ง PROSCANER_RELEASE=1 (BUILD_RELEASE.bat)
// และต้องเซ็นด้วยกุญแจของ ProScaner ถ้าเครื่องนี้ไม่มีกุญแจ (ห้ามเก็บกุญแจในคอมที่ติดไวรัส) จะเซ็นชั่วคราวด้วยกุญแจทดสอบ
// แล้วนำไปเซ็นจริงบนคลาวด์ก่อนใช้ ไฟล์ชั่วคราวนี้ห้ามติดตั้ง
// บิลด์อื่นทั้งหมดเป็นตัวทดสอบ: ชื่อแพ็กเกจเดิม (com.obddoctor.obd_doctor) เซ็นด้วยกุญแจทดสอบของเครื่อง
// จึงติดตั้งทับแอปเดิมในแท็บเล็ตได้ ข้อมูลเดิมไม่หาย และไม่มีทางไปทับแอปตัวจริง
val proscanerRelease = System.getenv("PROSCANER_RELEASE") == "1"

// กุญแจแอปตัวจริง: android/key.properties (storeFile, storePassword, keyAlias, keyPassword)
// หรือตัวแปรระบบ PROSCANER_KEYSTORE, PROSCANER_KEYSTORE_PASSWORD, PROSCANER_KEY_ALIAS, PROSCANER_KEY_PASSWORD
val releaseKey: Map<String, String>? = run {
    val props = Properties()
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { props.load(it) }
    fun v(prop: String, env: String): String? =
        props.getProperty(prop)?.takeIf { it.isNotBlank() } ?: System.getenv(env)?.takeIf { it.isNotBlank() }
    val store = v("storeFile", "PROSCANER_KEYSTORE")
    val storePass = v("storePassword", "PROSCANER_KEYSTORE_PASSWORD")
    val alias = v("keyAlias", "PROSCANER_KEY_ALIAS") ?: "proscaner"
    val keyPass = v("keyPassword", "PROSCANER_KEY_PASSWORD") ?: storePass
    if (store != null && storePass != null && keyPass != null && file(store).exists()) {
        mapOf("store" to store, "storePass" to storePass, "alias" to alias, "keyPass" to keyPass)
    } else {
        null
    }
}

if (proscanerRelease) {
    logger.lifecycle(
        "ProScaner: building the REAL app com.proscaner.app " +
            if (releaseKey != null) "(signed with the ProScaner key)" else "(NOT signed yet - sign it in the cloud before installing)",
    )
}

android {
    namespace = "com.obddoctor.obd_doctor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // ชื่อแพ็กเกจ: แอปตัวจริงใช้ com.proscaner.app (ถาวร ห้ามเปลี่ยนหลังแจกแอป) ตัวทดสอบใช้ชื่อเดิม
        // (namespace ข้างบนเป็นชื่อแพ็กเกจของโค้ด Kotlin ไม่เกี่ยวกับชื่อแอป ไม่ต้องเปลี่ยน)
        applicationId = if (proscanerRelease) "com.proscaner.app" else "com.obddoctor.obd_doctor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ชื่อแอปบนหน้าจอ: แอปตัวจริง "ProScaner" ตัวทดสอบ "ProScaner ทดสอบ" (debug ใช้ "ProScaner TEST")
        manifestPlaceholders["appLabel"] = if (proscanerRelease) "ProScaner" else "ProScaner ทดสอบ"
    }

    signingConfigs {
        val key = releaseKey
        if (key != null) {
            create("proscaner") {
                storeFile = file(key.getValue("store"))
                storePassword = key.getValue("storePass")
                keyAlias = key.getValue("alias")
                keyPassword = key.getValue("keyPass")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            // ProScaner: debug/test builds install as a separate app (<applicationId>.test),
            // so testing on a phone never replaces or wipes the real app and its data.
            applicationIdSuffix = ".test"
            manifestPlaceholders["appLabel"] = "ProScaner TEST"
        }
        release {
            // แอปตัวจริงเซ็นด้วยกุญแจของ ProScaner เท่านั้น ตัวทดสอบเซ็นด้วยกุญแจทดสอบของเครื่องเสมอ
            // (ถึงเครื่องนี้มีกุญแจตัวจริง ตัวทดสอบก็ไม่ใช้ จะได้อัปเดตทับตัวทดสอบเดิมได้)
            signingConfig = if (proscanerRelease && releaseKey != null) {
                signingConfigs.getByName("proscaner")
            } else {
                signingConfigs.getByName("debug")
            }
            // ProScaner: keep release code exactly as written (same as debug).
            // shared_preferences_android and other plugins built on package:jni are
            // called from Dart by exact Java class and method signatures. R8 renamed
            // kotlin.coroutines.Continuation, so loading settings failed at startup
            // (NoSuchMethodError ... SharedPreferencesApiRegistrar.getAll) and the app
            // stayed on a black screen. If you turn R8 back on, keep proguard-rules.pro.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
