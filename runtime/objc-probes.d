typedef void *Class;
typedef const char *SEL;
typedef void *IMP;

provider objc_runtime
{
    // Exception handling
    probe objc_exception_throw(void *id);
    probe objc_exception_rethrow();

    // Initialization time things; you may need to use
    //
    //   dtrace -x evaltime=preinit -Z
    //
    // in order to catch everything
    probe load_image(const char *name, int bundle, int hasClassProperties, int preoptimized);

    // Different phases of initialization
    probe first_time__start();
    probe first_time__end();

    probe fixup_selectors__start();
    probe fixup_selectors__end();

    probe discover_classes__start();
    probe discover_classes__end();

    probe remap_classes__start();
    probe remap_classes__end();

    probe fixup_vtables__start();
    probe fixup_vtables__end();

    probe discover_protocols__start();
    probe discover_protocols__end();

    probe fixup_protocols__start();
    probe fixup_protocols__end();

    probe discover_categories__start();
    probe discover_categories__end();

    probe realize_non_lazy_classes__start();
    probe realize_non_lazy_classes__end();

    probe realize_future_classes__start();
    probe realize_future_classes__end();

    // Method cache
    probe cache_miss(void *id, SEL sel, Class cls);
    probe cache_flush(Class cls);

    // Autorelease
    probe autorelease_pool__push(void *token);
    probe autorelease_pool__pop(void *token);

    // Fires when we add a new page to an autorelease pool
    probe autorelease_pool__grow(int depth);
};
