package android.app;

import android.content.ContextWrapper;

/** Application must also be a ContextWrapper when called through JNI. */
public class Application extends ContextWrapper {
    public Application() {
        super(null);
    }

    public interface ActivityLifecycleCallbacks {
        void onActivityCreated(Activity activity, android.os.Bundle savedInstanceState);
        void onActivityStarted(Activity activity);
        void onActivityResumed(Activity activity);
        void onActivityPaused(Activity activity);
        void onActivityStopped(Activity activity);
        void onActivitySaveInstanceState(Activity activity, android.os.Bundle outState);
        void onActivityDestroyed(Activity activity);
    }

    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {}

    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {}
}
