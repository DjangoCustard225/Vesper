#include "UsenetCrypto.h"
#include <string.h>
#include <stdlib.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonCrypto.h>
#else
/* Opaque OpenSSL 3 ABI declarations keep Linux verification independent of development headers.
   Apple builds use CommonCrypto and do not link or ship OpenSSL. */
typedef struct evp_md_st EVP_MD;
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
extern const EVP_MD *EVP_sha256(void);
extern EVP_MD_CTX *EVP_MD_CTX_new(void);
extern void EVP_MD_CTX_free(EVP_MD_CTX *);
extern int EVP_DigestInit_ex(EVP_MD_CTX *, const EVP_MD *, void *);
extern int EVP_DigestUpdate(EVP_MD_CTX *, const void *, size_t);
extern int EVP_DigestFinal_ex(EVP_MD_CTX *, unsigned char *, unsigned int *);
extern unsigned char *HMAC(const EVP_MD *, const void *, int, const unsigned char *, size_t, unsigned char *, unsigned int *);
extern const EVP_CIPHER *EVP_aes_128_cbc(void);
extern const EVP_CIPHER *EVP_aes_256_cbc(void);
extern EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
extern void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
extern int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *, const unsigned char *, const unsigned char *);
extern int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);
extern int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
extern int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
#endif

static void wipe(void *buffer, size_t length) { volatile uint8_t *p = buffer; while (length--) *p++ = 0; }
static uint32_t rotate(uint32_t value, unsigned shift) { return (value << shift) | (value >> (32 - shift)); }
typedef struct { uint32_t state[5]; uint64_t bytes; size_t used; uint8_t buffer[64]; } SHA1State;
static void sha1_block(SHA1State *ctx, const uint8_t block[64], uint8_t *expanded) {
    uint32_t w[80];
    for (unsigned i = 0; i < 16; ++i) w[i] = (uint32_t)block[i*4] << 24 | (uint32_t)block[i*4+1] << 16 | (uint32_t)block[i*4+2] << 8 | block[i*4+3];
    for (unsigned i = 16; i < 80; ++i) w[i] = rotate(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    uint32_t a=ctx->state[0], b=ctx->state[1], c=ctx->state[2], d=ctx->state[3], e=ctx->state[4];
    for (unsigned i = 0; i < 80; ++i) {
        uint32_t f, k;
        if (i < 20) { f=(b & c) | (~b & d); k=0x5a827999; }
        else if (i < 40) { f=b ^ c ^ d; k=0x6ed9eba1; }
        else if (i < 60) { f=(b & c) | (b & d) | (c & d); k=0x8f1bbcdc; }
        else { f=b ^ c ^ d; k=0xca62c1d6; }
        uint32_t next=rotate(a,5)+f+e+k+w[i]; e=d; d=c; c=rotate(b,30); b=a; a=next;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d; ctx->state[4]+=e;
    if (expanded) for (unsigned i=0;i<16;++i) for (unsigned j=0;j<4;++j) expanded[i*4+j]=(uint8_t)(w[i+64]>>(8*j));
    wipe(w,sizeof(w));
}
static void sha1_update(SHA1State *ctx, const uint8_t *data, size_t length) {
    ctx->bytes += length;
    while (length) {
        size_t amount=64-ctx->used; if (amount>length) amount=length;
        memcpy(ctx->buffer+ctx->used,data,amount); ctx->used+=amount; data+=amount; length-=amount;
        if (ctx->used==64) { sha1_block(ctx,ctx->buffer,NULL); ctx->used=0; }
    }
}
static void sha1_rar_update(SHA1State *ctx, uint8_t *data, size_t length) {
    size_t first=64-ctx->used;
    if (length<first) { sha1_update(ctx,data,length); return; }
    sha1_update(ctx,data,first); data+=first; length-=first;
    /* RAR3 preserves a historical mutation of full password blocks for long passwords. */
    while (length>=64) { sha1_block(ctx,data,data); ctx->bytes+=64; data+=64; length-=64; }
    sha1_update(ctx,data,length);
}
static void sha1_finish(SHA1State ctx, uint8_t digest[20]) {
    uint64_t bits=ctx.bytes*8;
    uint8_t pad[72]={0x80}; size_t count=ctx.used<56 ? 56-ctx.used : 120-ctx.used;
    sha1_update(&ctx,pad,count);
    for (unsigned i=0;i<8;++i) pad[i]=(uint8_t)(bits>>(56-8*i));
    sha1_update(&ctx,pad,8);
    for (unsigned i=0;i<5;++i) for (unsigned j=0;j<4;++j) digest[i*4+j]=(uint8_t)(ctx.state[i]>>(24-8*j));
    wipe(&ctx,sizeof(ctx)); wipe(pad,sizeof(pad));
}
int vesper_rar3_key(const uint8_t *password,size_t length,const uint8_t *salt,size_t salt_length,uint8_t key[16],uint8_t iv[16]) {
    if (!password || length>512 || (salt_length!=0 && salt_length!=8)) return 0;
    uint8_t raw[520]; memcpy(raw,password,length); if (salt_length) memcpy(raw+length,salt,salt_length); length+=salt_length;
    SHA1State ctx={{0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0},0,0,{0}};
    uint8_t hash[20], number[3];
    for (unsigned round=0;round<262144;++round) {
        sha1_rar_update(&ctx,raw,length);
        number[0]=(uint8_t)round; number[1]=(uint8_t)(round>>8); number[2]=(uint8_t)(round>>16);
        sha1_update(&ctx,number,3);
        if (round%16384==0) { sha1_finish(ctx,hash); iv[round/16384]=hash[19]; }
    }
    sha1_finish(ctx,hash);
    for (unsigned i=0;i<4;++i) for (unsigned j=0;j<4;++j) key[4*i+j]=hash[4*i+3-j];
    wipe(raw,sizeof(raw)); wipe(hash,sizeof(hash)); wipe(&ctx,sizeof(ctx)); return 1;
}
static int hmac256(const uint8_t *key,size_t key_length,const uint8_t *input,size_t length,uint8_t output[32]) {
#ifdef __APPLE__
    CCHmac(kCCHmacAlgSHA256,key,key_length,input,length,output); return 1;
#else
    unsigned written=0; return HMAC(EVP_sha256(),key,(int)key_length,input,length,output,&written)!=NULL && written==32;
#endif
}
int vesper_sha256(const uint8_t *input,size_t length,uint8_t output[32]) {
#ifdef __APPLE__
    return CC_SHA256(input,(CC_LONG)length,output)!=NULL;
#else
    EVP_MD_CTX *ctx=EVP_MD_CTX_new(); if (!ctx) return 0; unsigned written=0;
    int ok=EVP_DigestInit_ex(ctx,EVP_sha256(),NULL)==1 && EVP_DigestUpdate(ctx,input,length)==1 && EVP_DigestFinal_ex(ctx,output,&written)==1 && written==32;
    EVP_MD_CTX_free(ctx); return ok;
#endif
}
int vesper_rar5_key(const uint8_t *password,size_t length,const uint8_t salt[16],unsigned log_rounds,uint8_t key[32],uint8_t check[8]) {
    if (!password || length>1024 || log_rounds>20) return 0;
    uint8_t input[20], u[32], next[32], accumulated[32]; memcpy(input,salt,16); memset(input+16,0,4); input[19]=1;
    if (!hmac256(password,length,input,20,u)) return 0; memcpy(accumulated,u,32);
    unsigned rounds=1U<<log_rounds; memset(check,0,8);
    for (unsigned i=1;i<rounds+32;++i) {
        if (i==rounds) memcpy(key,accumulated,32);
        if (!hmac256(password,length,u,32,next)) { wipe(u,32); wipe(next,32); wipe(accumulated,32); return 0; }
        memcpy(u,next,32); for (unsigned j=0;j<32;++j) accumulated[j]^=u[j];
    }
    for (unsigned i=0;i<32;++i) check[i%8]^=accumulated[i];
    wipe(u,32); wipe(next,32); wipe(accumulated,32); return 1;
}
int vesper_aes_decrypt(const uint8_t *key,size_t key_length,const uint8_t iv[16],const uint8_t *input,size_t length,uint8_t *output) {
    if ((key_length!=16 && key_length!=32) || length==0 || length%16 || length>4194336) return 0;
#ifdef __APPLE__
    size_t written=0;
    return CCCrypt(kCCDecrypt,kCCAlgorithmAES,0,key,key_length,iv,input,length,output,length,&written)==kCCSuccess && written==length;
#else
    EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new(); if (!ctx) return 0; int first=0,last=0;
    int ok=EVP_DecryptInit_ex(ctx,key_length==16?EVP_aes_128_cbc():EVP_aes_256_cbc(),NULL,key,iv)==1 && EVP_CIPHER_CTX_set_padding(ctx,0)==1 && EVP_DecryptUpdate(ctx,output,&first,input,(int)length)==1 && EVP_DecryptFinal_ex(ctx,output+first,&last)==1 && (size_t)(first+last)==length;
    EVP_CIPHER_CTX_free(ctx); return ok;
#endif
}
