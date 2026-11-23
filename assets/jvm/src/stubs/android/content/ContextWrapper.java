package android.content;

/** Desktop ContextWrapper, including Android's base-context relationship. */
public class ContextWrapper extends Context {
    private Context base;

    public ContextWrapper(Context base) {
        this.base = base;
    }

    protected void attachBaseContext(Context base) {
        this.base = base;
    }

    @Override
    public Context getBaseContext() {
        return base == null ? this : base;
    }

    @Override
    public Context getApplicationContext() {
        return base == null ? super.getApplicationContext() : base.getApplicationContext();
    }

    @Override
    public ClassLoader getClassLoader() {
        return base == null ? super.getClassLoader() : base.getClassLoader();
    }

    @Override
    public void setClassLoader(ClassLoader loader) {
        if (base == null) super.setClassLoader(loader);
        else base.setClassLoader(loader);
    }
}
