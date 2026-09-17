/* Note: A large part of this code has been borrowed/stolen/adapted from raindrops. */

#include <ruby.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
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
    int fd;
    struct slot *slots;
};

static int memory_page_close_fd(struct memory_page *page)
{
    int ret = 0;
    if (page->fd != -1) {
        ret = close(page->fd);
        page->fd = -1;
    }
    return ret;
}

static int memory_page_unmap(struct memory_page *page)
{
    int ret = 0;
    if (page->slots != MAP_FAILED) {
        ret = munmap(page->slots, slot_size * page->capa);
        if (ret == 0) {
            page->slots = MAP_FAILED;
        }
    }
    return ret;
}

static void memory_page_free(void *ptr)
{
    struct memory_page *page = (struct memory_page *)ptr;

    if (memory_page_unmap(page)) {
        rb_bug("Pitchfork::MemoryPage munmap failed in gc: %s", strerror(errno));
    }

    if (memory_page_close_fd(page)) {
        rb_warn("Pitchfork::MemoryPage close failed in GC, was it closed twice?");
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
    page->fd = -1;
    return obj;
}

static struct memory_page *memory_page_get_raw(VALUE self)
{
    struct memory_page *page;
    TypedData_Get_Struct(self, struct memory_page, &memory_page_type, page);
    return page;
}

static struct memory_page *memory_page_get(VALUE self)
{
    struct memory_page *page = memory_page_get_raw(self);
    if (page->slots == MAP_FAILED) {
        rb_raise(rb_eStandardError, "invalid or freed Pitchfork::MemoryPage");
    }
    return page;
}

static void memory_page_map(struct memory_page *page, size_t map_size)
{
    int tries = 1;

retry_mmap:
    page->slots = mmap(NULL, map_size, PROT_READ|PROT_WRITE, MAP_SHARED, page->fd, 0);

    if (page->slots == MAP_FAILED) {
        int err = errno;

        if ((err == EAGAIN || err == ENOMEM) && tries-- > 0) {
            rb_gc();
            goto retry_mmap;
        }

        memory_page_close_fd(page);
        rb_sys_fail("mmap");
    }
}

static VALUE memory_page_for_fd(VALUE klass, VALUE fd_val)
{
    VALUE self = memory_page_alloc(klass);
    struct memory_page *page = memory_page_get_raw(self);

    int fd = NUM2INT(fd_val);
    struct stat shm_stat;
    if (fstat(fd, &shm_stat)) {
        rb_sys_fail("fstat");
    }
    page->fd = fd;
    page->size = page->capa = shm_stat.st_size / slot_size;

    memory_page_map(page, shm_stat.st_size);
    return self;
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

static VALUE memory_page_fileno(VALUE self)
{
    struct memory_page *page = memory_page_get(self);
    return INT2NUM(page->fd);
}

static VALUE memory_page_close(VALUE self)
{
    struct memory_page *page = memory_page_get_raw(self);

    if (memory_page_unmap(page)) {
        rb_sys_fail("munmap");
    }

    if (memory_page_close_fd(page)) {
        rb_sys_fail("close");
    }

    return Qnil;
}

static VALUE memory_page_closed_p(VALUE self)
{
    struct memory_page *page = memory_page_get_raw(self);
    return (page->fd == -1 || page->slots == MAP_FAILED) ? Qtrue : Qfalse;
}

static VALUE memory_page_close_on_exec_p(VALUE self)
{
    struct memory_page *page = memory_page_get(self);
    int ret = fcntl(page->fd, F_GETFD);
    if (ret == -1) {
        rb_sys_fail("fcntl F_GETFD");
    }

    return (ret & FD_CLOEXEC) ? Qtrue : Qfalse;
}

static VALUE memory_page_close_on_exec_set(VALUE self, VALUE close_on_exec)
{
    struct memory_page *page = memory_page_get(self);
    int ret = fcntl(page->fd, F_GETFD);
    if (ret == -1) {
        rb_sys_fail("fcntl F_GETFD");
    }

    int flag = RTEST(close_on_exec) ? FD_CLOEXEC : 0;
    flag = (ret & ~FD_CLOEXEC) | flag;

    if (fcntl(page->fd, F_SETFD, flag) == -1) {
        rb_sys_fail("fcntl F_SETFD");
    }

    return close_on_exec;
}

#define SHM_NAME_BUF_SIZE 50

static VALUE memory_page_initialize(VALUE self, VALUE size)
{
    struct memory_page *page;
    TypedData_Get_Struct(self, struct memory_page, &memory_page_type, page);

    if (page->slots != MAP_FAILED) {
        rb_raise(rb_eRuntimeError, "already initialized");
    }

    page->size = NUM2SIZET(size);
    if (page->size < 1) {
        rb_raise(rb_eArgError, "size must be >= 1");
    }

    size_t map_size = PAGE_ALIGN(slot_size * page->size);
    page->capa = map_size / slot_size;
    assert(PAGE_ALIGN(slot_size * page->capa) == map_size && "not aligned");

    char name[SHM_NAME_BUF_SIZE];

retry_shm_open:
    if (snprintf(name, SHM_NAME_BUF_SIZE, "/pitchfork-%d", rand()) < 0) {
        rb_sys_fail("snprintf");
    }

    page->fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (page->fd == -1) {
        if (errno == EEXIST) {
            goto retry_shm_open;
        }
        rb_sys_fail("shm_open");
    }

    if (shm_unlink(name) == -1) {
        memory_page_close_fd(page);
        rb_sys_fail("shm_unlink");
    }

    if (ftruncate(page->fd, map_size)) {
        memory_page_close_fd(page);
        rb_sys_fail("ftruncate");
    }

    memory_page_map(page, map_size);

    memset(page->slots, 0, map_size);

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

    rb_define_singleton_method(rb_cMemoryPage, "for_fd", memory_page_for_fd, 1);

    rb_define_private_method(rb_cMemoryPage, "initialize", memory_page_initialize, 1);
    rb_define_method(rb_cMemoryPage, "[]", memory_page_aref, 1);
    rb_define_method(rb_cMemoryPage, "[]=", memory_page_aset, 2);
    rb_define_method(rb_cMemoryPage, "fileno", memory_page_fileno, 0);
    rb_define_method(rb_cMemoryPage, "close", memory_page_close, 0);
    rb_define_method(rb_cMemoryPage, "closed?", memory_page_closed_p, 0);
    rb_define_method(rb_cMemoryPage, "close_on_exec?", memory_page_close_on_exec_p, 0);
    rb_define_method(rb_cMemoryPage, "close_on_exec=", memory_page_close_on_exec_set, 1);
}
