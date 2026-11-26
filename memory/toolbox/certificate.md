---
name: certificate
description: TLS 证书查看命令：本地证书文件字段、在线检查站点证书（SNI）、从 K8s Secret 取证书看过期时间
metadata:
  type: reference
---

# 证书

## 1. 查看本地证书文件

```bash
openssl x509 -in <CERT>.pem -noout -text                  # 全量
openssl x509 -in <CERT>.pem -noout -dates -issuer -subject -ext subjectAltName
openssl x509 -in <CERT>.pem -noout -fingerprint -sha256   # 不加 -sha256 默认是 SHA1 指纹
```
- 可组合字段：`-dates` 有效期、`-subject` 主题、`-issuer` 签发者、`-fingerprint` 指纹、`-ext subjectAltName` SAN（需 OpenSSL ≥ 1.1.1，旧版用 `-text | grep -A1 'Subject Alternative Name'`）。
- 判断即将过期：`openssl x509 -in <CERT>.pem -noout -checkend $((30*86400))`（30 天内过期返回非 0）。

## 2. 在线检查站点证书

```bash
# -servername 必带：多证书/SNI 场景下不带会拿到默认证书，误判"证书不对"
openssl s_client -connect <HOST>:443 -servername <HOST> -showcerts </dev/null

# 直接看对端证书的有效期/SAN
openssl s_client -connect <HOST>:443 -servername <HOST> </dev/null 2>/dev/null \
  | openssl x509 -noout -dates -subject -ext subjectAltName
```
- 关注输出里的 `Verify return code`：非 0 常见于中间证书链不完整（服务端只配了叶子证书）。
- 指向特定后端 IP 但仍用域名 SNI：`-connect <IP>:443 -servername <HOST>`。

## 3. K8s Secret 中的证书

```bash
kubectl get secret <SECRET> -n <NS> -o json | jq -r '.data | keys[]'      # 看有哪些 key
kubectl get secret <SECRET> -n <NS> -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -dates -subject -ext subjectAltName
```
- jsonpath 里 key 中的 `.` 要转义成 `\.`。
