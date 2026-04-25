#!/bin/bash
# Diagnose email infrastructure for a domain.
# Usage: diagnose_email.sh <domain> [resend_api_key]
#
# Checks: MX records, SPF, DKIM, DMARC, Resend domain status,
#         Resend receiving capability, recent inbound emails.

set -euo pipefail

DOMAIN="${1:-}"
RESEND_KEY="${2:-${RESEND_API_KEY:-}}"

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: diagnose_email.sh <domain> [resend_api_key]"
    echo "Example: diagnose_email.sh example.com"
    echo "Set RESEND_API_KEY env var or pass it as the second arg to enable Resend checks."
    exit 1
fi

PASS=0
FAIL=0
WARN=0

ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

echo "========================================="
echo "Email Infrastructure Diagnosis: $DOMAIN"
echo "========================================="
echo ""

# 1. MX Records
echo "1. MX Records"
MX=$(dig MX "$DOMAIN" +short 2>/dev/null)
if [[ -z "$MX" ]]; then
    fail "No MX records found for $DOMAIN"
else
    echo "  Found: $MX"
    if echo "$MX" | grep -qi "inbound-smtp"; then
        ok "MX points to inbound-smtp (AWS SES / Resend)"
    else
        warn "MX does not point to inbound-smtp. Emails may not reach Resend."
    fi
fi
echo ""

# 2. SPF Record
echo "2. SPF Record"
SPF=$(dig TXT "$DOMAIN" +short 2>/dev/null | grep -i "v=spf1" || true)
if [[ -z "$SPF" ]]; then
    fail "No SPF record found"
else
    echo "  Found: $SPF"
    if echo "$SPF" | grep -qi "resend.com"; then
        ok "SPF includes resend.com"
    else
        warn "SPF does not include resend.com"
    fi
    if echo "$SPF" | grep -qi "amazonses.com"; then
        ok "SPF includes amazonses.com"
    else
        warn "SPF does not include amazonses.com"
    fi
fi
echo ""

# 3. DKIM Record
echo "3. DKIM Record"
DKIM=$(dig TXT "resend._domainkey.$DOMAIN" +short 2>/dev/null || true)
if [[ -z "$DKIM" ]]; then
    fail "No DKIM record found at resend._domainkey.$DOMAIN"
else
    ok "DKIM record exists"
fi
echo ""

# 4. DMARC Record
echo "4. DMARC Record"
DMARC=$(dig TXT "_dmarc.$DOMAIN" +short 2>/dev/null || true)
if [[ -z "$DMARC" ]]; then
    warn "No DMARC record found (optional but recommended)"
else
    echo "  Found: $DMARC"
    ok "DMARC record exists"
fi
echo ""

# 5. Resend Domain Status
echo "5. Resend Domain Status"
if [[ -n "$RESEND_KEY" ]]; then
    DOMAINS_JSON=$(curl -s "https://api.resend.com/domains" -H "Authorization: Bearer $RESEND_KEY" 2>/dev/null)
    DOMAIN_ENTRY=$(echo "$DOMAINS_JSON" | jq -r --arg d "$DOMAIN" '.data[] | select(.name == $d)' 2>/dev/null)

    if [[ -z "$DOMAIN_ENTRY" || "$DOMAIN_ENTRY" == "null" ]]; then
        fail "Domain $DOMAIN not found in Resend account"
    else
        STATUS=$(echo "$DOMAIN_ENTRY" | jq -r '.status')
        SENDING=$(echo "$DOMAIN_ENTRY" | jq -r '.capabilities.sending')
        RECEIVING=$(echo "$DOMAIN_ENTRY" | jq -r '.capabilities.receiving')
        REGION=$(echo "$DOMAIN_ENTRY" | jq -r '.region')

        echo "  Status: $STATUS | Region: $REGION"
        echo "  Sending: $SENDING | Receiving: $RECEIVING"

        if [[ "$STATUS" == "verified" ]]; then
            ok "Domain is verified"
        else
            fail "Domain status is '$STATUS' (needs 'verified')"
        fi

        if [[ "$SENDING" == "enabled" ]]; then
            ok "Sending is enabled"
        else
            fail "Sending is disabled"
        fi

        if [[ "$RECEIVING" == "enabled" ]]; then
            ok "Receiving is enabled"
        else
            fail "RECEIVING IS DISABLED — emails sent to @$DOMAIN will NOT arrive"
            echo "  → Fix: Enable receiving in Resend dashboard for $DOMAIN"
        fi
    fi
else
    warn "No RESEND_API_KEY — skipping Resend API checks"
fi
echo ""

# 6. Recent Inbound Emails
echo "6. Recent Inbound Emails to @$DOMAIN"
if [[ -n "$RESEND_KEY" ]]; then
    EMAILS=$(curl -s "https://api.resend.com/emails/receiving" -H "Authorization: Bearer $RESEND_KEY" 2>/dev/null)
    DOMAIN_EMAILS=$(echo "$EMAILS" | jq -r --arg d "@$DOMAIN" '[.data[] | select(.to[] | contains($d))] | length' 2>/dev/null || echo "0")

    if [[ "$DOMAIN_EMAILS" -gt 0 ]]; then
        ok "$DOMAIN_EMAILS emails received at @$DOMAIN"
        echo "  Most recent:"
        echo "$EMAILS" | jq -r --arg d "@$DOMAIN" '.data[] | select(.to[] | contains($d)) | "    \(.created_at) | \(.from) → \(.to[0]) | \(.subject)"' 2>/dev/null | head -5
    else
        warn "No emails found for @$DOMAIN in recent inbound"
        echo "  This could mean: receiving was recently enabled, or emails aren't arriving"
    fi
else
    warn "No RESEND_API_KEY — skipping inbound email check"
fi
echo ""

# 7. Send test email (optional — just report what would need to happen)
echo "7. Test Email"
echo "  To send a test: curl -X POST https://api.resend.com/emails \\"
echo "    -H 'Authorization: Bearer \$RESEND_API_KEY' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"from\":\"test@example.com\",\"to\":\"test@$DOMAIN\",\"subject\":\"Delivery test\",\"text\":\"Test\"}'"
echo ""

# Summary
echo "========================================="
echo "SUMMARY: $PASS passed, $FAIL failed, $WARN warnings"
echo "========================================="

if [[ "$FAIL" -gt 0 ]]; then
    echo "FIX THE FAILURES ABOVE before building email workarounds."
    exit 1
else
    echo "Infrastructure looks good. Run: touch ~/.claude/.email_infra_checked"
    exit 0
fi
