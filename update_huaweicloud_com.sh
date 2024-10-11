#!/bin/sh
#
# 用于华为云解析的DNS更新脚本
# 2023-2024 sxlehua <sxlehua at qq dot com>
# 华为云解析API文档 https://support.huaweicloud.com/api-dns/dns_api_62003.html
# 华为云API签名文档 https://support.huaweicloud.com/api-dns/dns_api_30003.html
#
# 本脚本由 dynamic_dns_functions.sh 内的函数 send_update() 调用
#
# 需要在 /etc/config/ddns 中设置的选项
# option username - 华为云API访问账号 Access Key Id,参考https://support.huaweicloud.com/devg-apisign/api-sign-provide-aksk.html获取.
# option password - 华为云API访问密钥 Secret Access Key
# option domain   - 完整的域名。建议主机与域名之间使用 @符号 分隔，否则将以第一个 .符号 之前的内容作为主机名
#

# 检查传入参数
[ -z "$username" ] && write_log 14 "配置错误！保存华为云API访问账号的'用户名'不能为空"
[ -z "$password" ] && write_log 14 "配置错误！保存华为云API访问密钥的'密码'不能为空"

[ -z "$CURL" ] && [ -z "$CURL_SSL" ] && write_log 14 "使用华为云API需要 curl和SSL支持，请先安装"
command -v openssl >/dev/null 2>&1 || write_log 14 "使用华为云API需要 openssl-util 支持，请先安装"
command -v sed >/dev/null 2>&1 || write_log 14 "使用华为云API需要 sed 支持，请先安装"

# 公共变量
local __HOST __DOMAIN __TYPE __ZONE_ID __RECORD_ID
local __ENDPOINT="dns.cn-north-1.myhuaweicloud.com"
local __TTL=120
[ $use_ipv6 -eq 0 ] && __TYPE="A" || __TYPE="AAAA"

# 从 $domain 分离主机和域名
[ "${domain:0:2}" == "@." ] && domain="${domain/./}" # 主域名处理
[ "$domain" == "${domain/@/}" ] && domain="${domain/./@}" # 未找到分隔符，兼容常用域名格式
__HOST="${domain%%@*}"
__DOMAIN="${domain#*@}"
[ -z "$__HOST" -o "$__HOST" == "$__DOMAIN" ] && __HOST="@"

hcloud_transfer() {
    local method=$1
    local path=$2
    local query=$3
    local body=$4

    local timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    local contentType=""
    if [ ! "$method" = "GET" ]; then
        contentType="application/json"
    fi
    local _H_Content_Type=""
    
    local canonicalUri="${path}"
    # 如果canonicalUri不以/结尾，则添加/
    echo $canonicalUri | grep -qE "/$" || canonicalUri="$canonicalUri/"
    local canonicalQuery="$query" # 后期可能需要增加URL编码

    local canonicalHeaders="host:$__ENDPOINT\nx-sdk-date:$timestamp\n"
    local signedHeaders="host;x-sdk-date"

    if [ ! "$contentType" = "" ]; then
        canonicalHeaders="content-type:$contentType\n${canonicalHeaders}"
        signedHeaders="content-type;$signedHeaders"
        _H_Content_Type="Content-Type: ${contentType}"
    fi

    local hexencode=$(printf "%s" "$body" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.* //')
    local canonicalRequest="$method\n$canonicalUri\n$canonicalQuery\n$canonicalHeaders\n$signedHeaders\n$hexencode"
    canonicalRequest="$(printf "$canonicalRequest%s")"

    local stringToSign="SDK-HMAC-SHA256\n$timestamp\n$(printf "%s" "$canonicalRequest" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.* //')"
    stringToSign="$(printf "$stringToSign%s")"

    local signature=$(printf "%s" "$stringToSign" | openssl dgst -sha256 -hmac "$password" 2>/dev/null | sed 's/^.* //')
    authorization="SDK-HMAC-SHA256 Access=$username, SignedHeaders=$signedHeaders, Signature=$signature"
    
    reqUrl="$__ENDPOINT$path"
    if [ ! -z "$query" ]; then
        reqUrl="$reqUrl""?$query"
    fi

    curl -s -X "${method}" \
        -H "Host: $__ENDPOINT" \
        -H "$_H_Content_Type" \
        -H "Authorization: $authorization" \
        -H "X-Sdk-Date: $timestamp" \
        -d "${body}" \
        "https://$reqUrl"

    if [ $? -ne 0 ]; then
        write_log 14 "rest api error"
    fi
}

get_zone() {
  local resp=`hcloud_transfer GET /v2/zones "name=$__DOMAIN.&search_mode=equal" ""`
  __ZONE_ID=`printf "%s" $resp |  grep -Eo '"id":"[a-z0-9]+"' | cut -d':' -f2 | tr -d '"'`
  if [ "$__ZONE_ID" = "" ]; then
    write_log 14 "error, no zone"
  fi
}

upd_record() {
  local body="{\"name\":\"$__HOST.$__DOMAIN.\",\"type\":\"$__TYPE\",\"records\":[\"$__IP\"],\"ttl\":$__TTL}"
  local resp=`hcloud_transfer PUT /v2/zones/"$__ZONE_ID"/recordsets/$__RECORD_ID "" "$body"`
  local recordId=`printf "%s" $resp |  grep -Eo '"id":"[a-z0-9]+"' | cut -d':' -f2 | tr -d '"'`
  if [ ! "$recordId" = "" ]; then
    write_log 7 "upd [$recordId] success [$__TYPE] [$__IP]"
  else
    write_log 14 "upd ecord error [$resp]"
  fi
}

add_record() {
  local body="{\"name\":\"$__HOST.$__DOMAIN.\",\"type\":\"$__TYPE\",\"records\":[\"$__IP\"],\"ttl\":$__TTL}"
  local resp=`hcloud_transfer POST /v2/zones/"$__ZONE_ID"/recordsets "" "$body"`
  local recordId=`printf "%s" $resp |  grep -Eo '"id":"[a-z0-9]+"' | cut -d':' -f2 | tr -d '"'`
  if [ ! "$recordId" = "" ]; then
    write_log 7 "add [$recordId] success [$__TYPE] [$__IP]"
  else
    write_log 14 "add record error [$resp]"
  fi
}

# 获取Record id
get_record() {
  local ret=0
  local resp=`hcloud_transfer GET /v2/zones/$__ZONE_ID/recordsets "name=$__HOST.$__DOMAIN.&search_mode=equal" ""`
  __RECORD_ID=`printf "%s" $resp |  grep -Eo '"id":"[a-z0-9]+"' | cut -d':' -f2 | tr -d '"' | head -1`
  if [ "$__RECORD_ID" = "" ]; then
    # 不存在记录，需要添加
    ret=1
  else
    local remoteIp=`printf "%s" $resp | grep -Eo '"records":\[[^]]+]' | cut -d ':' -f 2-10 | tr -d '[' | tr -d ']' | tr -d '"' | head -1`
    if [ ! "$remoteIp" = "$__IP" ]; then
      # 存在记录且不相等，需要修改记录
      ret=2
    fi
  fi
  return $ret
}

get_zone
get_record

ret=$?
if [ $ret -eq 0 ]; then
  write_log 7 "nochg [$__IP]"
fi
if [ $ret -eq 1 ]; then
  add_record
fi
if [ $ret -eq 2 ]; then
  upd_record
fi
