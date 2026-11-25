plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// 产品版本与桌面客户端一致（client/src-tauri/tauri.conf.json）；发布时 CI 按 tag 改写（.github/scripts/set-version.mjs）
val appVersion = "0.4.0"

/**
 * versionCode 由版本号算出：主版本 × 1000000 + 次版本 × 10000 + 修订号 × 100 + 后缀（rc.N → N，正式版 → 99）。
 * 例：0.4.0-rc.1 → 40001，0.4.0 → 40099，0.4.1 → 40199。只增不减，rc 总比同版本的正式版小，
 * 装了 rc 的设备可以直接升级到正式版；不用手动维护，同一个版本号算出来的总是同一个值
 */
val appVersionCode: Int = run {
    val m = requireNotNull(Regex("""(\d+)\.(\d+)\.(\d+)(?:-rc\.(\d+))?""").matchEntire(appVersion)) {
        "appVersion must be X.Y.Z or X.Y.Z-rc.N, got $appVersion"
    }
    val (major, minor, patch, rc) = m.destructured
    val suffix = if (rc.isEmpty()) 99 else rc.toInt()
    require(minor.toInt() <= 99 && patch.toInt() <= 99 && (rc.isEmpty() || suffix in 1..98)) {
        "appVersion $appVersion is out of range for versionCode: minor and patch go up to 99, rc.N from 1 to 98"
    }
    major.toInt() * 1_000_000 + minor.toInt() * 10_000 + patch.toInt() * 100 + suffix
}

/** 构建参数：先找 Gradle 属性（-Pairhand.server=...），再找环境变量（AIRHAND_SERVER） */
fun setting(prop: String, env: String): String? =
    (findProperty(prop) as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv(env)?.takeIf { it.isNotBlank() }

// 中转服务器地址和证书指纹的默认值编译进程序（和桌面版一样），装好之后可以在"设置"里改
val defaultServer = setting("airhand.server", "AIRHAND_SERVER") ?: "127.0.0.1:4433"
val defaultFingerprint = setting("airhand.serverFp", "AIRHAND_SERVER_FP") ?: ""
run {
    // 指纹写错了在构建时就报错（规则与 airhand_link::net::parse_fingerprint 相同）
    val hexDigits = "0123456789abcdef"
    val ok = defaultFingerprint.all { it.isWhitespace() || it == ':' || it.lowercaseChar() in hexDigits }
    val digits = defaultFingerprint.count { it.lowercaseChar() in hexDigits }
    require(ok && (digits == 0 || digits == 64)) {
        "AIRHAND_SERVER_FP must be the 64 hex digit fingerprint printed in the server log (`:` and spaces are allowed)"
    }
}

// 编译哪些 ABI 的 Rust 库：默认手机 / 电视常见的三种；调试时可以只编一种（-Pairhand.abis=x86_64）
val rustAbis = (setting("airhand.abis", "AIRHAND_ABIS") ?: "arm64-v8a,armeabi-v7a,x86_64")
    .split(',').map { it.trim() }.filter { it.isNotEmpty() }

// 发布版签名：设置了 AIRHAND_KEYSTORE 就用它，否则用调试签名（这样构建出来的 APK 也能直接安装）
val keystore = setting("airhand.keystore", "AIRHAND_KEYSTORE")?.let { file(it) }

android {
    namespace = "app.airhand.android"
    compileSdk = 35
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "app.airhand.android"
        minSdk = 24
        targetSdk = 35
        versionCode = appVersionCode
        versionName = appVersion
        buildConfigField("String", "DEFAULT_SERVER", "\"${defaultServer.replace("\"", "")}\"")
        buildConfigField("String", "DEFAULT_SERVER_FP", "\"${defaultFingerprint.trim()}\"")
        ndk { abiFilters += rustAbis }
    }

    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = keystore
                storePassword = setting("airhand.keystorePassword", "AIRHAND_KEYSTORE_PASSWORD")
                keyAlias = setting("airhand.keyAlias", "AIRHAND_KEY_ALIAS")
                keyPassword = setting("airhand.keyPassword", "AIRHAND_KEY_PASSWORD")
                    ?: setting("airhand.keystorePassword", "AIRHAND_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    sourceSets["main"].jniLibs.srcDir(layout.buildDirectory.dir("rustJniLibs"))
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
    lint {
        checkReleaseBuilds = true
        abortOnError = true
        fatal += "NewApi"
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.all { test ->
            // MessagesTest 直接读 Rust 源码里的 Problem / NoticeView 和两种语言的 strings.xml，检查每一种都有文案。
            // 把这些文件声明为输入：只改了 Rust 或者只改了某一种语言时测试也会重新跑，不会被当成"已是最新"跳过
            val repo = rootProject.projectDir.parentFile
            test.systemProperty("airhand.repo", repo.absolutePath)
            test.inputs.files(
                repo.resolve("crates/airhand-link/src/problem.rs"),
                repo.resolve("crates/airhand-link/src/controller/session.rs"),
                repo.resolve("crates/airhand-proto/src/session.rs"),
            ).withPropertyName("rustMessageEnums").withPathSensitivity(PathSensitivity.RELATIVE)
            // ProtocolTest 读和 Rust、桌面控制台共用的协议样例
            test.inputs.file(repo.resolve("crates/airhand-link/tests/protocol.json"))
                .withPropertyName("protocolFixture").withPathSensitivity(PathSensitivity.RELATIVE)
            test.inputs.files(fileTree("src/main/res") { include("values*/strings.xml") })
                .withPropertyName("strings").withPathSensitivity(PathSensitivity.RELATIVE)
        }
    }
}

base {
    archivesName.set("Airhand-$appVersion")
}

// ───────────── Rust 核心：用 cargo-ndk 编译 ../native，输出到 build/rustJniLibs/<abi>/ ─────────────
val cargoBuild by tasks.registering(Exec::class) {
    description = "Builds the Rust core (android/native) for $rustAbis with cargo-ndk"
    group = "build"
    val nativeDir = rootProject.file("native")
    val outDir = layout.buildDirectory.dir("rustJniLibs").get().asFile
    workingDir = nativeDir
    inputs.dir(nativeDir.resolve("src"))
    inputs.files(nativeDir.resolve("Cargo.toml"), nativeDir.resolve("Cargo.lock"))
    inputs.dir(rootProject.file("../crates"))
    inputs.property("abis", rustAbis)
    outputs.dir(outDir)
    doFirst {
        environment("ANDROID_NDK_HOME", android.ndkDirectory.absolutePath)
        // CI 的运行环境预先把 ANDROID_NDK_ROOT 设成它自带的 NDK：不一致的话 cargo-ndk 会警告（它用的是 ANDROID_NDK_HOME）
        environment("ANDROID_NDK_ROOT", android.ndkDirectory.absolutePath)
    }
    val args = mutableListOf("cargo", "ndk")
    rustAbis.forEach { args += listOf("-t", it) }
    args += listOf("--platform", "24", "-o", outDir.absolutePath, "build", "--release")
    commandLine(args)
}
tasks.named("preBuild") { dependsOn(cargoBuild) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.json)
}
