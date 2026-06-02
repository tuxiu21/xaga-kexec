/* Add an empty `regulator-always-on` property to every node whose
 * `regulator-name` matches one of the names given on the command line.
 * Operates in-place on the binary DTB via libfdt -- no decompile/recompile,
 * so the bootloader's runtime fixups (memory, reserved-memory, /chosen) are
 * preserved byte-for-byte; only the requested properties are added.
 *   usage: dtb_always_on <in.dtb> <out.dtb> <regulator-name>...
 *
 * Build (uses the kernel tree's libfdt, no flex/bison needed):
 *   L=sources/Xiaomi_Kernel_OpenSource/scripts/dtc/libfdt
 *   gcc -O2 -I"$L" -o dtb_always_on src/dtb_always_on.c "$L"/*.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libfdt.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <in.dtb> <out.dtb> <regulator-name>...\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open in"); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    long cap = sz + 8192;                 /* slack for new props + strings */
    char *buf = malloc(cap);
    if (!buf || fread(buf, 1, sz, f) != (size_t)sz) { fprintf(stderr, "read fail\n"); return 1; }
    fclose(f);

    int r = fdt_check_header(buf);
    if (r) { fprintf(stderr, "not a valid dtb: %s\n", fdt_strerror(r)); return 1; }
    r = fdt_open_into(buf, buf, cap);     /* make it expandable for rw ops */
    if (r) { fprintf(stderr, "fdt_open_into: %s\n", fdt_strerror(r)); return 1; }

    int added = 0, changed = 1;
    while (changed) {                     /* restart scan after each edit: offsets shift */
        changed = 0;
        for (int off = fdt_next_node(buf, -1, NULL); off >= 0; off = fdt_next_node(buf, off, NULL)) {
            const char *rn = fdt_getprop(buf, off, "regulator-name", NULL);
            if (!rn) continue;
            int match = 0;
            for (int i = 3; i < argc; i++) if (!strcmp(rn, argv[i])) { match = 1; break; }
            if (!match) continue;
            if (fdt_getprop(buf, off, "regulator-always-on", NULL)) continue;  /* already has it */
            r = fdt_setprop(buf, off, "regulator-always-on", NULL, 0);
            if (r) { fprintf(stderr, "setprop %s: %s\n", rn, fdt_strerror(r)); return 1; }
            printf("  + always-on -> %s\n", rn);
            added++; changed = 1; break;
        }
    }

    /* self-verify: each requested name must be found and now carry always-on */
    int ok = 1;
    for (int i = 3; i < argc; i++) {
        int found = 0, has = 0;
        for (int off = fdt_next_node(buf, -1, NULL); off >= 0; off = fdt_next_node(buf, off, NULL)) {
            const char *rn = fdt_getprop(buf, off, "regulator-name", NULL);
            if (rn && !strcmp(rn, argv[i])) { found = 1; has = fdt_getprop(buf, off, "regulator-always-on", NULL) ? 1 : 0; break; }
        }
        printf("  verify %-18s found=%d always-on=%d\n", argv[i], found, has);
        if (!found || !has) ok = 0;
    }

    fdt_pack(buf);
    int total = fdt_totalsize(buf);
    FILE *o = fopen(argv[2], "wb");
    if (!o) { perror("open out"); return 1; }
    fwrite(buf, 1, total, o); fclose(o);
    printf("added=%d  out=%s size=%d  verify_all=%s\n", added, argv[2], total, ok ? "OK" : "FAIL");
    return ok ? 0 : 3;
}
