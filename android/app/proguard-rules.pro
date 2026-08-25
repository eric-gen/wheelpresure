# Flutter plugins use reflection-free platform channels, but keep their
# entry points intact.
-keep class io.flutter.plugin.** { *; }
-keep class com.example.flutter_application_1.** { *; }

# flutter_blue_plus
-keep class dev.britannio.flutter_blue_plus.** { *; }
-keep class com.lib.flutter_blue_plus.** { *; }

# permission_handler
-keep class com.baseflow.permissionhandler.** { *; }
