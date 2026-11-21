plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.carty.carty_example"
    // Pin compileSdk explicitly rather than tracking the (sometimes-lagging)
    // Flutter default, keeping the app and every plugin library module on one
    // SDK level. (Originally forced by file_picker's transitive
    // flutter_plugin_android_lifecycle; file_picker was dropped for file_selector,
    // but the explicit pin still keeps plugin modules aligned — see
    // ../build.gradle.kts.)
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.carty.carty_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Carty targets real Android hardware: build the
        // native FFI bridge for the device ABI only.
        ndk {
            abiFilters += "arm64-v8a"
        }

        // Only the FFI bridge ships in the APK — not the ctest executables the
        // same CMakeLists defines for the host dev loop.
        externalNativeBuild {
            cmake {
                targets += "carty_bridge"
            }
        }
    }

    // Cross-compile the Carty native bridge (the single FFI surface Dart loads)
    // into the APK as lib/arm64-v8a/libcarty.so. Same CMakeLists as
    // the host build; on Android it links the in-process LiteRT-LM engine in-process
    // (Route 1) whenever the arm64 runtime .so is vendored (CARTY_HAVE_LITERT),
    // holding Gemma 4 E2B resident in CartyModel — no subprocess. Absent .so →
    // honest ENOMODEL.
    externalNativeBuild {
        cmake {
            path = file("../../../native/CMakeLists.txt")
        }
    }

    // The in-process LiteRT-LM runtime (liblitert-lm.so) is a PREBUILT vendored .so
    // linked by absolute path in native/CMakeLists.txt. CMake/AGP only auto-package
    // libraries it BUILDS (libcarty.so and the constraint-provider stub, a build
    // dependency) — never a prebuilt external lib — so ship liblitert-lm.so via
    // jniLibs to satisfy libcarty.so's DT_NEEDED at load time. The vendored layout
    // (litert-runtime/lib/<abi>/liblitert-lm.so) already matches jniLibs'
    // <abi>/lib*.so convention, so point straight at it (no copy step). A fresh
    // clone without the .so simply packages nothing → the bridge degrades to ENOMODEL.
    sourceSets {
        getByName("main") {
            jniLibs.srcDir("../../../litert-runtime/lib")
        }
    }

    // The vendored tree carries lib/x86_64/liblitert-lm.so for the HEADLESS host
    // dev loop — a glibc binary, NOT an Android x86_64 .so. jniLibs can't tell the
    // two "x86_64"s apart by ABI name, so exclude the host blob explicitly: it must
    // never ship in an APK (dead weight on a real device; a load-time breaker if an
    // x86_64 emulator build ever re-links it). arm64-v8a is the only product ABI
    //; abiFilters drops the rest, this guards the one it can't.
    packaging {
        jniLibs {
            excludes += "**/x86_64/liblitert-lm.so"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // ARCore VIO — the deliberate on-device platform-dependency exception
    //: 6-DoF pose, floor plane, intrinsics. Runs entirely
    // on-device and offline; no cloud inference is involved.
    implementation("com.google.ar:core:1.54.0")
}

flutter {
    source = "../.."
}
