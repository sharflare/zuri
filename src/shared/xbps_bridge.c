#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xbps.h>

struct xbps_handle *zuri_xbps_init(const char *rootdir, const char *cachedir,
                                   int flags) {
  struct xbps_handle *xhp = calloc(1, sizeof(*xhp));
  if (!xhp)
    return NULL;

  if (rootdir)
    strncpy(xhp->rootdir, rootdir, sizeof(xhp->rootdir) - 1);
  if (cachedir)
    strncpy(xhp->cachedir, cachedir, sizeof(xhp->cachedir) - 1);
  xhp->flags = flags;

  if (xbps_init(xhp) != 0) {
    free(xhp);
    return NULL;
  }
  return xhp;
}

void zuri_xbps_end(struct xbps_handle *xhp) {
  if (xhp) {
    xbps_end(xhp);
    free(xhp);
  }
}

int zuri_repo_store(struct xbps_handle *xhp, const char *repo_url) {
  return xbps_repo_store(xhp, repo_url) ? 0 : -1;
}

int zuri_rpool_sync(struct xbps_handle *xhp) {
  return xbps_rpool_sync(xhp, NULL);
}

void zuri_free_str_array(char **arr, size_t count) {
  if (!arr)
    return;
  for (size_t i = 0; i < count; i++)
    free(arr[i]);
  free(arr);
}

// --- transaction pkg list ---

typedef struct {
  char *pkgver;
  char *filename;
  char *sha256;
  uint64_t size;
} ZuriPkgDownload;

ZuriPkgDownload *zuri_transaction_pkgs(struct xbps_handle *xhp, size_t *count) {
  *count = 0;
  if (!xhp->transd)
    return NULL;

  xbps_array_t pkgs = xbps_dictionary_get(xhp->transd, "packages");
  if (!pkgs)
    return NULL;

  size_t n = xbps_array_count(pkgs);
  ZuriPkgDownload *result = calloc(n, sizeof(*result));
  if (!result)
    return NULL;

  size_t out = 0;
  for (size_t i = 0; i < n; i++) {
    xbps_dictionary_t pkg = xbps_array_get(pkgs, i);
    if (!pkg)
      continue;

    xbps_trans_type_t trans_type = xbps_transaction_pkg_type(pkg);
    if (trans_type != XBPS_TRANS_INSTALL && trans_type != XBPS_TRANS_UPDATE)
      continue;

    const char *pkgver = NULL;
    xbps_dictionary_get_cstring_nocopy(pkg, "pkgver", &pkgver);
    if (!pkgver)
      continue;

    const char *arch = NULL;
    xbps_dictionary_get_cstring_nocopy(pkg, "architecture", &arch);

    char fname[512];
    const char *fname_dict = NULL;
    if (xbps_dictionary_get_cstring_nocopy(pkg, "filename", &fname_dict) &&
        fname_dict) {
      strncpy(fname, fname_dict, sizeof(fname) - 1);
      fname[sizeof(fname) - 1] = '\0';
    } else if (arch && strcmp(arch, "noarch") != 0) {
      snprintf(fname, sizeof(fname), "%s.%s.xbps", pkgver, arch);
    } else {
      snprintf(fname, sizeof(fname), "%s.xbps", pkgver);
    }

    const char *sha = NULL;
    xbps_dictionary_get_cstring_nocopy(pkg, "filename-sha256", &sha);

    uint64_t fsz = 0;
    xbps_dictionary_get_uint64(pkg, "filename-size", &fsz);

    result[out].pkgver = strdup(pkgver);
    result[out].filename = strdup(fname);
    result[out].sha256 = sha ? strdup(sha) : strdup("");
    result[out].size = fsz;
    out++;
  }
  *count = out;
  return result;
}

void zuri_free_pkg_downloads(ZuriPkgDownload *arr, size_t count) {
  if (!arr)
    return;
  for (size_t i = 0; i < count; i++) {
    free(arr[i].pkgver);
    free(arr[i].filename);
    free(arr[i].sha256);
  }
  free(arr);
}

static int zuri_saved_stderr = -1;

void zuri_stderr_suppress(void) {
  if (zuri_saved_stderr != -1)
    return;
  fflush(stderr);
  zuri_saved_stderr = dup(2);
  if (zuri_saved_stderr == -1)
    return;
  int null_fd = open("/dev/null", O_WRONLY);
  if (null_fd == -1) {
    close(zuri_saved_stderr);
    zuri_saved_stderr = -1;
    return;
  }
  dup2(null_fd, 2);
  close(null_fd);
}

void zuri_stderr_restore(void) {
  if (zuri_saved_stderr == -1)
    return;
  fflush(stderr);
  dup2(zuri_saved_stderr, 2);
  close(zuri_saved_stderr);
  zuri_saved_stderr = -1;
}
