/*
 * Known-answer probe for the WiredTiger public API (mayhem/test.sh oracle). Prints one
 * deterministic line per check; test.sh diffs the output against mayhem/kat/expected.txt.
 */
#include <wiredtiger.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CK(x)                                                   \
    do {                                                        \
        int ck_ret = (x);                                       \
        if (ck_ret != 0) {                                      \
            fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #x, ck_ret); \
            exit(1);                                            \
        }                                                       \
    } while (0)

static void
kat_table(const char *home)
{
    WT_CONNECTION *conn;
    WT_CURSOR *c;
    WT_SESSION *s;
    char key[16], val[32];
    const char *k, *v;
    int i, ret;
    long sum;

    CK(wiredtiger_open(home, NULL, "create,cache_size=10MB", &conn));
    CK(conn->open_session(conn, NULL, NULL, &s));
    CK(s->create(s, "table:kat", "key_format=S,value_format=S"));
    CK(s->open_cursor(s, "table:kat", NULL, NULL, &c));
    for (i = 0; i < 100; i++) {
        snprintf(key, sizeof(key), "key%03d", i);
        snprintf(val, sizeof(val), "value-%d", i * i);
        c->set_key(c, key);
        c->set_value(c, val);
        CK(c->insert(c));
    }
    c->set_key(c, "key042");
    CK(c->search(c));
    CK(c->get_value(c, &v));
    printf("search key042=%s\n", v);

    c->set_key(c, "key500");
    ret = c->search(c);
    printf("search key500=%s\n", ret == WT_NOTFOUND ? "notfound" : "found");

    c->set_key(c, "key042");
    c->set_value(c, "updated");
    CK(c->update(c));
    c->set_key(c, "key042");
    CK(c->search(c));
    CK(c->get_value(c, &v));
    printf("after update key042=%s\n", v);

    c->set_key(c, "key007");
    CK(c->remove(c));
    c->set_key(c, "key007");
    ret = c->search(c);
    printf("after remove key007=%s\n", ret == WT_NOTFOUND ? "notfound" : "found");

    CK(c->reset(c));
    i = 0;
    sum = 0;
    while ((ret = c->next(c)) == 0) {
        CK(c->get_key(c, &k));
        if (i == 0)
            printf("first key=%s\n", k);
        sum += atol(k + 3);
        i++;
    }
    CK(ret == WT_NOTFOUND ? 0 : ret);
    printf("scan count=%d keysum=%ld\n", i, sum);
    CK(c->prev(c));
    CK(c->get_key(c, &k));
    printf("last key=%s\n", k);
    CK(c->close(c));

    CK(s->checkpoint(s, NULL));
    CK(conn->close(conn, NULL));

    /* Reopen from disk and confirm the data survived. */
    CK(wiredtiger_open(home, NULL, "cache_size=10MB", &conn));
    CK(conn->open_session(conn, NULL, NULL, &s));
    CK(s->open_cursor(s, "table:kat", NULL, NULL, &c));
    c->set_key(c, "key099");
    CK(c->search(c));
    CK(c->get_value(c, &v));
    printf("reopen key099=%s\n", v);
    CK(conn->close(conn, NULL));
}

static void
kat_modify(const char *home)
{
    WT_CONNECTION *conn;
    WT_CURSOR *c;
    WT_ITEM item;
    WT_MODIFY mod[2];
    WT_SESSION *s;
    char out[64];

    CK(wiredtiger_open(home, NULL, "create,cache_size=10MB", &conn));
    CK(conn->open_session(conn, NULL, NULL, &s));
    CK(s->create(s, "table:mod", "key_format=S,value_format=u"));
    CK(s->open_cursor(s, "table:mod", NULL, NULL, &c));

    memset(&item, 0, sizeof(item));
    item.data = "ABCDEFGHIJ";
    item.size = 10;
    c->set_key(c, "k");
    c->set_value(c, &item);
    CK(c->insert(c));

    memset(mod, 0, sizeof(mod));
    mod[0].data.data = "xyz1";
    mod[0].data.size = 4;
    mod[0].offset = 2;
    mod[0].size = 3;
    mod[1].data.data = "__";
    mod[1].data.size = 2;
    mod[1].offset = 0;
    mod[1].size = 0;
    CK(s->begin_transaction(s, NULL));
    c->set_key(c, "k");
    CK(c->modify(c, mod, 2));
    CK(s->commit_transaction(s, NULL));
    c->set_key(c, "k");
    CK(c->search(c));
    CK(c->get_value(c, &item));
    snprintf(out, sizeof(out), "%.*s", (int)item.size, (const char *)item.data);
    printf("modify result=%s size=%zu\n", out, item.size);
    CK(conn->close(conn, NULL));
}

static void
kat_config(void)
{
    WT_CONFIG_ITEM k, v;
    WT_CONFIG_PARSER *p;
    const char *cfg = "path=/dev/loop,page_size=1024,log=(file_max=20MB,remove=true),name=\"quoted str\"";
    int ret;

    CK(wiredtiger_config_parser_open(NULL, cfg, strlen(cfg), &p));
    while ((ret = p->next(p, &k, &v)) == 0)
        printf("config %.*s -> %.*s (type %d)\n", (int)k.len, k.str, (int)v.len, v.str,
          (int)v.type);
    CK(ret == WT_NOTFOUND ? 0 : ret);
    CK(p->close(p));

    CK(wiredtiger_config_parser_open(NULL, cfg, strlen(cfg), &p));
    v.type = WT_CONFIG_ITEM_NUM;
    CK(p->get(p, "log.file_max", &v));
    printf("config log.file_max=%ld\n", (long)v.val);
    CK(p->get(p, "page_size", &v));
    printf("config page_size=%ld\n", (long)v.val);
    ret = p->get(p, "missing", &v);
    printf("config missing=%s\n", ret == WT_NOTFOUND ? "notfound" : "found");
    CK(p->close(p));
}

static void
kat_pack(const char *home)
{
    WT_CONNECTION *conn;
    WT_SESSION *s;
    char buf[64], str[16];
    int64_t i64;
    size_t used;
    uint8_t b;
    const char *sp;
    int32_t i32;
    size_t i;

    CK(wiredtiger_open(home, NULL, "create", &conn));
    CK(conn->open_session(conn, NULL, NULL, &s));
    memset(buf, 0, sizeof(buf));
    CK(wiredtiger_struct_size(s, &used, "iSq", 300, "hi", (int64_t)-5));
    printf("pack size iSq=%zu\n", used);
    CK(wiredtiger_struct_pack(s, buf, sizeof(buf), "iSq", 300, "hi", (int64_t)-5));
    printf("pack bytes=");
    for (i = 0; i < used; i++) {
        b = (uint8_t)buf[i];
        printf("%02x", b);
    }
    printf("\n");
    CK(wiredtiger_struct_unpack(s, buf, used, "iSq", &i32, &sp, &i64));
    snprintf(str, sizeof(str), "%s", sp);
    printf("unpack i=%d S=%s q=%ld\n", i32, str, (long)i64);
    CK(conn->close(conn, NULL));
}

int
main(int argc, char *argv[])
{
    const char *home = argc > 1 ? argv[1] : ".";
    char path[1024];

    snprintf(path, sizeof(path), "%s", home);
    kat_table(path);
    kat_modify(path);
    kat_config();
    kat_pack(path);
    return (0);
}
