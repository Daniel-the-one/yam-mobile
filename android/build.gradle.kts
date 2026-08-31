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
// Certains plugins (flutter_webrtc) déclarent un compileSdk trop ancien
// pour les dépendances AndroidX résolues (>= 34). On force 36 partout.
// NB : enregistré AVANT evaluationDependsOn, sinon les projets sont déjà évalués.
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        val setter = androidExt.javaClass.methods.firstOrNull {
            (it.name == "setCompileSdkVersion" || it.name == "setCompileSdk") &&
                it.parameterTypes.size == 1 &&
                (it.parameterTypes[0] == Integer.TYPE || it.parameterTypes[0] == Integer::class.java)
        }
        try {
            setter?.invoke(androidExt, 36)
        } catch (_: Exception) {
            // Pas grave : le module gère déjà son compileSdk.
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
