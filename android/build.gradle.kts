allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 强制所有 Android 子工程（含 file_picker 等插件）使用 compileSdk 36。
// file_picker 8.3.7 硬编码 compileSdk 34，但其依赖 flutter_plugin_android_lifecycle 要求 ≥36，需统一提升。
// 仅影响编译期 API 级别，不改变 minSdk/targetSdk，无运行时行为变化。
// 必须在下方 evaluationDependsOn(":app") 之前注册 afterEvaluate：本回调需先于 AGP 自身的 afterEvaluate
// 执行（AGP 在其 afterEvaluate 里读取 compileSdk，之后再 set 会报 "too late"）。:app 自身已是 36，
// 重复 set 同值无害；:file_picker 等库插件的 34 会被覆盖为 36。
subprojects {
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileSdkVersion("android-36")
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
