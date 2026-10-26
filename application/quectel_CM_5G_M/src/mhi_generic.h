/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef QMODEM_MHI_GENERIC_H
#define QMODEM_MHI_GENERIC_H
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* No fixed controller/WWAN index and no QRTR node inference. */
struct cm_mhi_endpoint {
    char netdev[32];
    char control[128];
    int mbim;
};

static int cm_mhi_join(char *out, size_t size, const char *a, const char *b)
{
    int n = snprintf(out, size, "%s/%s", a, b);
    return n >= 0 && (size_t)n < size;
}

static int cm_mhi_inside(const char *parent, const char *child)
{
    size_t n = strlen(parent);
    return !strncmp(parent, child, n) && child[n] == '/';
}

/* 1: unique endpoint; 0: not generic MHI; -1: incomplete/ambiguous MHI. */
static int cm_mhi_detect(const char *sysroot, const char *devroot,
                         const char *expected, struct cm_mhi_endpoint *result)
{
    char netclass[PATH_MAX], wwanclass[PATH_MAX];
    struct dirent *ne;
    unsigned matches = 0;
    int seen = 0;
    if (!cm_mhi_join(netclass, sizeof(netclass), sysroot, "class/net") ||
        !cm_mhi_join(wwanclass, sizeof(wwanclass), sysroot, "class/wwan")) return -1;
    DIR *nets = opendir(netclass);
    if (!nets) return 0;
    while ((ne = readdir(nets))) {
        char path[PATH_MAX], real[PATH_MAX], controller[PATH_MAX], *part;
        int mbim = 0;
        if (ne->d_name[0] == '.' || (expected[0] && strcmp(expected, ne->d_name))) continue;
        if (!cm_mhi_join(path, sizeof(path), netclass, ne->d_name) || !realpath(path, real)) continue;
        snprintf(controller, sizeof(controller), "%s", real);
        part = strstr(controller, "/mhi");
        if (!part) continue;
        /* Accept only a controller component mhi[0-9]+, not vendor MHI names. */
        char *end = part + 4;
        if (*end < '0' || *end > '9') continue;
        while (*end >= '0' && *end <= '9') end++;
        if (*end != '/') continue;
        *end = '\0';
        seen = 1;
        if (strstr(real, "_IP_SW")) continue;
        if (strstr(real, "_IP_HW0/")) {
            char driverlink[PATH_MAX], driver[PATH_MAX];
            if (!cm_mhi_join(driverlink, sizeof(driverlink), path, "device/driver") ||
                !realpath(driverlink, driver) || strcmp(strrchr(driver, '/') + 1, "mhi_net")) continue;
        } else {
            char channel[PATH_MAX], driver[PATH_MAX];
            const char *name = strrchr(controller, '/') + 1;
            int n = snprintf(channel, sizeof(channel), "%s/%s_IP_HW0_MBIM/driver", controller, name);
            if (n < 0 || (size_t)n >= sizeof(channel) || !realpath(channel, driver) ||
                strcmp(strrchr(driver, '/') + 1, "mhi_wwan_mbim")) continue;
            mbim = 1;
        }
        DIR *ports = opendir(wwanclass);
        struct dirent *pe;
        unsigned controls = 0;
        char control[128] = "";
        if (!ports) continue;
        while ((pe = readdir(ports))) {
            char port[PATH_MAX], typepath[PATH_MAX], portreal[PATH_MAX], candidate[128], type[16] = "";
            if (pe->d_name[0] == '.' ||
                !cm_mhi_join(port, sizeof(port), wwanclass, pe->d_name) ||
                !realpath(port, portreal) || !cm_mhi_inside(controller, portreal) ||
                !cm_mhi_join(typepath, sizeof(typepath), port, "type")) continue;
            FILE *fp = fopen(typepath, "r");
            if (!fp) continue;
            int valid = fgets(type, sizeof(type), fp) && !strcmp(type, mbim ? "MBIM\n" : "QMI\n");
            fclose(fp);
            if (!valid || !cm_mhi_join(candidate, sizeof(candidate), devroot, pe->d_name) ||
                access(candidate, F_OK)) continue;
            strcpy(control, candidate);
            controls++;
        }
        closedir(ports);
        if (controls != 1) continue;
        if (strlen(ne->d_name) >= sizeof(result->netdev)) continue;
        strcpy(result->netdev, ne->d_name);
        strcpy(result->control, control);
        result->mbim = mbim;
        matches++;
    }
    closedir(nets);
    return matches == 1 ? 1 : (seen ? -1 : 0);
}
#endif
