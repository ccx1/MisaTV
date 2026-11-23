import android.app.Application;
import android.content.Context;
import android.content.ContextWrapper;

/** JNI looks up ContextWrapper methods and calls them on an Application. */
public final class ContextWrapperTest {
    public static void main(String[] args) throws Exception {
        Application app = new Application();
        check(app instanceof ContextWrapper, "Application must extend ContextWrapper");
        check(app.getBaseContext() == app, "desktop Application needs a usable base context");
        ClassLoader loader = new ClassLoader() {};
        app.setClassLoader(loader);
        check(ContextWrapper.class.getMethod("getClassLoader").invoke(app) == loader,
                "JNI ContextWrapper.getClassLoader must accept Application");

        Context base = new Context();
        ContextWrapper wrapper = new ContextWrapper(base);
        wrapper.setClassLoader(loader);
        check(wrapper.getBaseContext() == base, "wrapper must retain its base");
        check(wrapper.getClassLoader() == loader, "wrapper must delegate its loader");
        check(base.getClassLoader() == loader, "loader updates must reach the base");
        check(wrapper.getApplicationContext() == base.getApplicationContext(),
                "wrapper must delegate application context");
        check(Application.ActivityLifecycleCallbacks.class.isInterface(),
                "existing lifecycle callback ABI must be preserved");
        System.out.println("ContextWrapper/Application JNI compatibility: PASS");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
