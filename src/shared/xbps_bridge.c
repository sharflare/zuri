#include <ctype.h>
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

// --- Txn Pkg List ---

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
    if (trans_type != XBPS_TRANS_INSTALL && trans_type != XBPS_TRANS_UPDATE &&
        trans_type != XBPS_TRANS_REMOVE)
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

// --- Search ---

typedef struct {
  char *pkgver;
  char *short_desc;
  char *pkgname;
} ZuriSearchResult;

static int ci_strstr(const char *haystack, const char *needle) {
  if (!haystack || !needle)
    return 0;
  size_t nlen = strlen(needle);
  if (nlen == 0)
    return 1;
  size_t hlen = strlen(haystack);
  if (nlen > hlen)
    return 0;
  for (size_t i = 0; i <= hlen - nlen; i++) {
    size_t j;
    for (j = 0; j < nlen; j++) {
      if (tolower((unsigned char)haystack[i + j]) !=
          tolower((unsigned char)needle[j]))
        break;
    }
    if (j == nlen)
      return 1;
  }
  return 0;
}

static int is_dup(ZuriSearchResult *arr, size_t n, const char *name) {
  for (size_t i = 0; i < n; i++) {
    if (arr[i].pkgname && strcmp(arr[i].pkgname, name) == 0)
      return 1;
  }
  return 0;
}

static int search_repo_cb(struct xbps_repo *repo, void *arg, bool *loop_done) {
  (void)loop_done;
  ZuriSearchResult **res = (ZuriSearchResult **)(((void **)arg)[0]);
  size_t *n = (size_t *)(((void **)arg)[1]);
  size_t *cap = (size_t *)(((void **)arg)[2]);
  const char *pattern = (const char *)(((void **)arg)[3]);

  if (!repo->idx)
    return 0;

  xbps_array_t keys = xbps_dictionary_all_keys(repo->idx);
  if (!keys)
    return 0;

  size_t nkeys = xbps_array_count(keys);

  for (size_t i = 0; i < nkeys; i++) {
    xbps_object_t key_obj = xbps_array_get(keys, i);
    const char *pkgname = xbps_dictionary_keysym_cstring_nocopy(
        (xbps_dictionary_keysym_t)key_obj);
    if (!pkgname)
      continue;

    if (is_dup(*res, *n, pkgname))
      continue;

    xbps_dictionary_t pkgd = xbps_dictionary_get(repo->idx, pkgname);
    if (!pkgd)
      continue;

    const char *pkgver = NULL;
    const char *short_desc = NULL;
    xbps_dictionary_get_cstring_nocopy(pkgd, "pkgver", &pkgver);
    xbps_dictionary_get_cstring_nocopy(pkgd, "short_desc", &short_desc);
    if (!pkgver)
      continue;

    if (!ci_strstr(pkgver, pattern) && !ci_strstr(short_desc, pattern))
      continue;

    if (*n >= *cap) {
      size_t newcap = *cap * 2;
      ZuriSearchResult *tmp = realloc(*res, newcap * sizeof(**res));
      if (!tmp)
        return 0;
      *res = tmp;
      *cap = newcap;
    }

    (*res)[*n].pkgver = strdup(pkgver);
    (*res)[*n].short_desc = short_desc ? strdup(short_desc) : strdup("");
    (*res)[*n].pkgname = strdup(pkgname);
    if (!(*res)[*n].pkgver || !(*res)[*n].short_desc || !(*res)[*n].pkgname) {
      free((*res)[*n].pkgver);
      free((*res)[*n].short_desc);
      free((*res)[*n].pkgname);
      return 0;
    }
    (*n)++;
  }

  return 0;
}

ZuriSearchResult *zuri_rpool_search(struct xbps_handle *xhp,
                                    const char *pattern, size_t *count) {
  size_t cap = 256;
  size_t n = 0;
  ZuriSearchResult *results = calloc(cap, sizeof(*results));
  if (!results)
    return NULL;

  void *arg[4] = {&results, &n, &cap, (void *)pattern};
  xbps_rpool_foreach(xhp, search_repo_cb, arg);

  *count = n;
  return results;
}

void zuri_free_search_results(ZuriSearchResult *results, size_t count) {
  if (!results)
    return;
  for (size_t i = 0; i < count; i++) {
    free(results[i].pkgver);
    free(results[i].short_desc);
    free(results[i].pkgname);
  }
  free(results);
}

// --- Installed Check ---

int zuri_pkgdb_has_pkg(struct xbps_handle *xhp, const char *pkgname) {
  return xbps_pkgdb_get_pkg(xhp, pkgname) != NULL;
}

// --- StdErr ---

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
