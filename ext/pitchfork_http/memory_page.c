/* Note: A large part of this code has been borrowed/stolen/adapted from raindrops. */

#include <ruby.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>

#define PAGE_MASK               (~(page_size - 1))
#define PAGE_ALIGN(addr)        (((addr) + page_size - 1) & PAGE_MASK)

static size_t slot_size = 128;

static void init_slot_size(void)
{
    long tmp = 2;

#ifdef _SC_NPROCESSORS_CONF
    tmp = sysconf(_SC_NPROCESSORS_CONF);
#endif
    /* no point in padding on single CPU machines */
    if (tmp == 1) {
        slot_size = sizeof(unsigned long);
    }
#ifdef _SC_LEVEL1_DCACHE_LINESIZE
    if (tmp != 1) {
        tmp = sysconf(_SC_LEVEL1_DCACHE_LINESIZE);
        if (tmp > 0) {
            slot_size = (size_t)tmp;
        }
    }
#endif
}

static size_t page_size = (size_t)-1;

static void init_page_size(void)
{
#if defined(_SC_PAGE_SIZE)
    page_size = (size_t)sysconf(_SC_PAGE_SIZE);
#elif defined(_SC_PAGESIZE)
    page_size = (size_t)sysconf(_SC_PAGESIZE);
#elif defined(HAVE_GETPAGESIZE)
    page_size = (size_t)getpagesize();
#elif defined(PAGE_SIZE)
    page_size = (size_t)PAGE_SIZE;
#elif defined(PAGESIZE)
    page_size = (size_t)PAGESIZE;
#else
#  error unable to detect page size for mmap()
#endif
    if ((page_size == (size_t)-1) || (page_size < slot_size)) {
        rb_raise(rb_eRuntimeError, "system page size invalid: %llu", (unsigned long long)page_size);
    }
}

/* each slot is a counter */
struct slot {
    unsigned long counter;
} __attribute__((packed));

/* allow mmap-ed regions to store more than one counter */
struct memory_page {
    size_t size;
    size_t capa;
    struct slot *slots;
};

static void memory_page_free(void *ptr)
{
    struct memory_page *page = (struct memory_page *)ptr;

    if (page->slots != MAP_FAILED) {
        int rv = munmap(page->slots, slot_size * page->capa);
        if (rv != 0) {
            rb_bug("Pitchfork::MemoryPage munmap failed in gc: %s", strerror(errno));
        }
    }

    xfree(ptr);
}

static size_t memory_page_memsize(const void *ptr)
{
    const struct memory_page *page = (const struct memory_page *)ptr;
    size_t memsize = sizeof(struct memory_page);
    if (page->slots != MAP_FAILED) {
        memsize += slot_size * page->capa;
    }
    return memsize;
}

static const rb_data_type_t memory_page_type = {
    .wrap_struct_name = "Pitchfork::MemoryPage",
    .function = {
        .dmark = NULL,
        .dfree = memory_page_free,
        .dsize = memory_page_memsize,
    },
    .flags = RUBY_TYPED_WB_PROTECTED,
};

static VALUE memory_page_alloc(VALUE klass)
{
    struct memory_page *page;
    VALUE obj = TypedData_Make_Struct(klass, struct memory_page, &memory_page_type, page);

    page->slots = MAP_FAILED;
    return obj;
}

static struct memory_page *memory_page_get(VALUE self)
{
    struct memory_page *page;

    TypedData_Get_Struct(self, struct memory_page, &memory_page_type, page);

    if (page->slots == MAP_FAILED) {
        rb_raise(rb_eStandardError, "invalid or freed Pitchfork::MemoryPage");
    }

    return page;
}

static unsigned long *memory_page_address(VALUE self, VALUE index)
{
    struct memory_page *page = memory_page_get(self);
    unsigned long off = FIX2ULONG(index) * slot_size;

    if (off >= slot_size * page->size) {
        rb_raise(rb_eArgError, "offset overrun");
    }

    return (unsigned long *)((unsigned long)page->slots + off);
}


static VALUE memory_page_aref(VALUE self, VALUE index)
{
    return ULONG2NUM(*memory_page_address(self, index));
}

static VALUE memory_page_aset(VALUE self, VALUE index, VALUE value)
{
    unsigned long *addr = memory_page_address(self, index);
    *addr = NUM2ULONG(value);
    return value;
}

static VALUE memory_page_initialize(VALUE self, VALUE size)
{
    struct memory_page *page;
    TypedData_Get_Struct(self, struct memory_page, &memory_page_type, page);

    int tries = 1;

    if (page->slots != MAP_FAILED) {
        rb_raise(rb_eRuntimeError, "already initialized");
    }

    page->size = NUM2SIZET(size);
    if (page->size < 1) {
        rb_raise(rb_eArgError, "size must be >= 1");
    }

    size_t tmp = PAGE_ALIGN(slot_size * page->size);
    page->capa = tmp / slot_size;
    assert(PAGE_ALIGN(slot_size * page->capa) == tmp && "not aligned");

retry:
    page->slots = mmap(NULL, tmp, PROT_READ|PROT_WRITE, MAP_ANON|MAP_SHARED, -1, 0);

    if (page->slots == MAP_FAILED) {
        int err = errno;

        if ((err == EAGAIN || err == ENOMEM) && tries-- > 0) {
            rb_gc();
            goto retry;
        }
        rb_sys_fail("mmap");
    }

    memset(page->slots, 0, tmp);

    return self;
}

void init_pitchfork_memory_page(VALUE mPitchfork)
{
    init_slot_size();
    init_page_size();

    VALUE rb_cMemoryPage = rb_define_class_under(mPitchfork, "MemoryPage", rb_cObject);

    /*
     * The size of one page of memory for a mmap()-ed MemoryPage region.
     * Typically 4096 bytes under Linux.
     */
    rb_define_const(rb_cMemoryPage, "PAGE_SIZE", SIZET2NUM(page_size));

    /*
     * The size (in bytes) of a slot in a MemoryPage object.
     * This is the size of a word on single CPU systems and
     * the size of the L1 cache line size if detectable.
     *
     * Defaults to 128 bytes if undetectable.
     */
    rb_define_const(rb_cMemoryPage, "SLOT_SIZE", SIZET2NUM(slot_size));

    rb_define_const(rb_cMemoryPage, "SLOTS", SIZET2NUM(page_size / slot_size));

    /*
     * The maximum value a slot counter can hold
     */
    rb_define_const(rb_cMemoryPage, "SLOT_MAX", ULONG2NUM((unsigned long)-1));

    rb_define_alloc_func(rb_cMemoryPage, memory_page_alloc);
    rb_define_private_method(rb_cMemoryPage, "initialize", memory_page_initialize, 1);
    rb_define_method(rb_cMemoryPage, "[]", memory_page_aref, 1);
    rb_define_method(rb_cMemoryPage, "[]=", memory_page_aset, 2);
}
