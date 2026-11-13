// An uncompressed 2D texture the CPU wrote, over storage the GPU has not written (nvn_mtl.m tex_cpu_content): its storage is its content at first use, flushed or not, and a later CPU
// write is uploaded. Once the GPU writes its storage it becomes a GPU texture with the content it has (cpu_unc_drop), and CPU writes are no longer uploaded. Over storage the GPU already
// writes it stays a GPU texture, unless the CPU has rewritten that storage since. A span that reaches less than a page into the texture, and does not cover it, does not make it the GPU's
// (gws_sliver: Ocarina of Time's 260x260 terrain maps). Mario Kart World's terrain patches: R16, RG8, RGBA8, R11G11B10F and RGBA16 in a CPU_CACHED pool, never flushed, were zeros and every patch a flat plane.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static void finish(void) { CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK("GPU has no error", !mtl_last_commit_error()); }
enum { SIZE = 16, LARGE = 256, POOL = 1 << 20 };
static void fill(tex_t *t, void *mem, uint8_t v) {
    uint32_t w = t->d.width, h = t->d.height;
    uint8_t *linear = malloc((size_t)w * h * 4);
    for (uint32_t i = 0; i < w * h; i++) { linear[i * 4] = v; linear[i * 4 + 1] = v + 1; linear[i * 4 + 2] = v + 2; linear[i * 4 + 3] = 255; }
    CHECK("fixture swizzle succeeds", !nvn_swizzle(&t->d, 0, 0, linear, w * 4, mem));
    free(linear);
}
static uint8_t first_red(id<MTLTexture> image) {   // the red of texel (3, 5), read through a blit: the texture is private
    static id<MTLCommandQueue> queue; if (!queue) queue = [g_dev newCommandQueue];
    id<MTLBuffer> out = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    if (!image || !out) { fprintf(stderr, "nothing to read back\n"); return 0; }
    id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:image.parentTexture ?: image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(3, 5, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("readback completes", cb.status == MTLCommandBufferStatusCompleted);
    return *(uint8_t *)out.contents;
}
static id<MTLTexture> resolve(tex_t *t) { mtl_sub_begin(); id<MTLTexture> image = tex_mtl(t); CHECK("texture resolves", image != nil); finish(); return image; }
typedef struct { void *mem; pool_t pool; tex_t t; } fixture;
static tex_t texture_at(fixture *f, uint64_t serial, uint64_t off, uint32_t size, int format, uint32_t tex_flags) {
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = serial, .pool = &f->pool, .off = off, .mem = (uint8_t *)f->mem + off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = size, .height = size, .depth = 1, .levels = 1, .samples = 1, .flags = tex_flags};
    nvn_tex_layout(&t.d, &t.L);
    return t;
}
static void setup(fixture *f, uint64_t serial, uint32_t pool_flags, int format, uint32_t tex_flags) {
    if (posix_memalign(&f->mem, getpagesize(), POOL)) abort();
    memset(f->mem, 0, POOL);
    f->pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .mem = f->mem, .size = POOL, .flags = pool_flags};
    mtl_pool_add(f->mem, POOL);
    f->t = texture_at(f, serial, 0, SIZE, format, tex_flags);
}
static void teardown(fixture *f) { mtl_tex_release(&f->t); mtl_alias_drop_pool(&f->pool); mtl_pool_del(f->mem); mtl_drain(); free(f->mem); }
static const uint32_t CACHED = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;

int main(void) {
    @autoreleasepool {
        mtl_init();
        fixture f;
        setup(&f, 7001, CACHED, NVN_FORMAT_RGBA8, 0);
        fill(&f.t, f.mem, 40);
        mtl_tex_init(&f.t);
        CHECK("at first use the storage is the content", first_red(resolve(&f.t)) == 40);
        dm_guest_write_prepare(f.mem, f.t.L.size); fill(&f.t, f.mem, 80);
        CHECK("a later CPU write is uploaded", first_red(resolve(&f.t)) == 80);
        { tex_t rt = f.t; rt.serial = 7101; mtl_tex_gpu_written(&rt); }   // another texture over the same storage, rendered into
        CHECK("at the first GPU write over its storage it keeps the content it has", first_red(resolve(&f.t)) == 80);
        CHECK("and is no longer CPU-written", !tex_cpu_written(f.t.serial));
        dm_guest_write_prepare(f.mem, f.t.L.size); fill(&f.t, f.mem, 120);
        CHECK("and a CPU write is no longer uploaded", first_red(resolve(&f.t)) == 80);
        teardown(&f);

        setup(&f, 7002, CACHED, NVN_FORMAT_RGBA8, 0);
        mtl_tex_gpu_written(&f.t);
        fill(&f.t, f.mem, 40);
        CHECK("over storage the GPU writes it is not taken from storage", !tex_cpu_content(&f.t));
        teardown(&f);

        setup(&f, 7004, CACHED, NVN_FORMAT_RGBA8, 0);
        { tex_t rt = f.t; rt.serial = 7104; rt.mem = (uint8_t *)f.mem + POOL / 2; mtl_tex_gpu_written(&rt); }   // a render target in the second half of the pool
        fill(&f.t, f.mem, 40);
        mtl_tex_init(&f.t);
        CHECK("a GPU write elsewhere in its pool leaves its storage the content", first_red(resolve(&f.t)) == 40);
        teardown(&f);

        // A span's sliver inside a texture (gws_sliver): less than a page of it, not covering it. Ocarina of Time's terrain tiles
        setup(&f, 7040, CACHED, NVN_FORMAT_RGBA8, 0);
        nvn_dirty_add_range(f.mem, POOL);
        tex_t drawn = texture_at(&f, 7041, 0x40000, 68, NVN_FORMAT_RGBA8, 0);   // ends inside a page: its span reaches into the next texture
        uintptr_t pg = (uintptr_t)getpagesize(), drawn_end = (uintptr_t)drawn.mem + drawn.L.size, shared = drawn_end & ~(pg - 1);
        CHECK("fixture: the drawn texture ends inside a page", drawn_end != shared && drawn_end - shared < pg);
        tex_t filled = texture_at(&f, 7042, shared - (uintptr_t)f.mem, 68, NVN_FORMAT_RGBA8, 0);   // begins in that page
        mtl_tex_gpu_written(&drawn);
        dm_guest_write_prepare(filled.mem, filled.L.size); fill(&filled, filled.mem, 40);
        CHECK("a neighbour's span reaching less than a page into a texture does not make it the GPU's", !gws_owned((uintptr_t)filled.mem, (uintptr_t)filled.mem + filled.L.size));
        CHECK("and the texture is taken from its storage", tex_cpu_content(&filled));
        CHECK("while the drawn texture stays the GPU's", gws_owned((uintptr_t)drawn.mem, drawn_end));
        mtl_tex_release(&filled); mtl_tex_release(&drawn);
        nvn_dirty_remove_range(f.mem);
        teardown(&f);

        setup(&f, 7043, CACHED, NVN_FORMAT_RGBA8, 0);   // a remnant of an old span between two newer ones, inside a texture the CPU then filled
        nvn_dirty_add_range(f.mem, POOL);
        tex_t large = texture_at(&f, 7044, 0x40000, LARGE, NVN_FORMAT_RGBA8, 0);
        uintptr_t lo = (uintptr_t)large.mem, hi = lo + large.L.size, cut = lo + large.L.size / 2;
        mtl_tex_gpu_written(&large);
        pthread_mutex_lock(&g_gws_mu); gws_set(lo, cut); gws_set(cut + 2560, hi); pthread_mutex_unlock(&g_gws_mu);
        CHECK("fixture: three spans, the middle one 2,560 bytes", g_ngws >= 3 && g_gws[gws_find(cut)].lo == cut && g_gws[gws_find(cut)].hi == cut + 2560);
        dm_guest_write_prepare(large.mem, large.L.size); fill(&large, large.mem, 40);
        CHECK("a sub-page remnant of an old span inside a texture the CPU rewrote does not keep it the GPU's", !gws_owned(lo, hi));
        CHECK("and the texture is taken from its storage", tex_cpu_content(&large));
        mtl_tex_release(&large);
        nvn_dirty_remove_range(f.mem);
        teardown(&f);

        setup(&f, 7045, CACHED, NVN_FORMAT_RGBA8, 0);   // a texture smaller than a page over storage the GPU wrote stays the GPU's
        nvn_dirty_add_range(f.mem, POOL);
        CHECK("fixture: the texture is smaller than a page", f.t.L.size > 0 && f.t.L.size < (uint64_t)getpagesize());
        tex_t beside = texture_at(&f, 7046, f.t.L.size, SIZE, NVN_FORMAT_RGBA8, 0);
        mtl_tex_gpu_written(&f.t);
        dm_guest_write_prepare(beside.mem, beside.L.size); fill(&beside, beside.mem, 40);
        CHECK("a texture smaller than a page over storage the GPU wrote stays the GPU's", gws_owned((uintptr_t)f.t.mem, (uintptr_t)f.t.mem + f.t.L.size));
        CHECK("though a neighbour in its page is CPU-written", !tex_cpu_content(&f.t) && tex_cpu_content(&beside));
        mtl_tex_release(&beside);
        nvn_dirty_remove_range(f.mem);
        teardown(&f);

        setup(&f, 7030, CACHED, NVN_FORMAT_RGBA8, 0);   // nvn_ft_poll's question (mtl_tex_cpu_rewritten)
        nvn_dirty_add_range(f.mem, POOL);
        large = texture_at(&f, 7031, 0x40000, LARGE, NVN_FORMAT_RGBA8, 0);
        dm_guest_write_prepare(large.mem, large.L.size); fill(&large, large.mem, 40);
        CHECK("a rewrite of storage the GPU never wrote is uploaded", mtl_tex_cpu_rewritten(&large) == MTL_REWRITE_UPLOADED && tex_cpu_written(large.serial));
        mtl_tex_gpu_written(&large);
        mtl_sub_begin(); cpu_unc_drop(); finish();
        CHECK("and the GPU's next write there makes it a GPU texture again", !tex_cpu_written(large.serial));
        dm_guest_write_prepare(large.mem, large.L.size); fill(&large, large.mem, 80);
        CHECK("and the CPU's next rewrite is uploaded", mtl_tex_cpu_rewritten(&large) == MTL_REWRITE_UPLOADED && tex_cpu_written(large.serial));
        mtl_tex_release(&large);
        nvn_dirty_remove_range(f.mem);
        teardown(&f);

        setup(&f, 7034, CACHED, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);   // a render target: not taken from storage, and once it has a host texture the usage test keeps it the GPU's
        fill(&f.t, f.mem, 40);
        CHECK("a compressible texture is not taken from storage", !tex_storage_ok(&f.t, 1));
        (void)resolve(&f.t);
        CHECK("a resolved render-target texture is left to the GPU", mtl_tex_cpu_rewritten(&f.t) == MTL_REWRITE_GPU && !tex_cpu_written(f.t.serial));
        teardown(&f);

        setup(&f, 7022, NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, NVN_FORMAT_RGBA8, 0);
        size_t spans = g_ngws;
        mtl_tex_gpu_written(&f.t);
        CHECK("storage the CPU cannot write gets no span", g_ngws == spans);
        teardown(&f);

        setup(&f, 7003, CACHED, NVN_FORMAT_RGBA8, 0);
        CHECK("storage of zeros is not taken", !tex_cpu_content(&f.t));
        teardown(&f);

        static const struct { const char *label; int format; uint32_t flags; } left_out[] = {
            {"a display texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY},
            {"a video-decode texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_VIDEO_DECODE},
            {"a shader image stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_IMAGE},
            {"a compressible texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE},
            {"a depth texture stays a GPU texture", NVN_FORMAT_DEPTH32F, 0},
        };
        for (unsigned i = 0; i < sizeof left_out / sizeof *left_out; i++) {
            setup(&f, 7010 + i, CACHED, left_out[i].format, left_out[i].flags);
            memset(f.mem, 0x55, f.t.L.size);
            CHECK(left_out[i].label, !tex_cpu_content(&f.t));
            teardown(&f);
        }
    }
    printf("t_cpu_storage: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
