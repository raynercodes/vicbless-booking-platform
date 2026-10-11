#!/usr/bin/env bash
# Vicbless: adds the two domain helper scripts (HTTPS certificate request, and the DNS record printer). Run from the REPO ROOT:
#   bash add-vicbless-domain-scripts.sh
#   infra/request-certificate.sh   requests ONE certificate for vicbless.com, www and dev, prints the Namecheap records
#   infra/dns-records.sh           prints the record that points dev (or prod) at the deployed site
# It touches nothing else (no workflows, no README). If a file already exists and differs, it is left alone and reported.
# It runs no git commands. Safe to run twice.
set -euo pipefail
if [ ! -d .git ] || [ ! -d infra ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and infra/)."
  exit 1
fi
put() { # put <path>  (content on stdin)
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [ ! -f "$1" ]; then cp "$tmp" "$1"; chmod +x "$1"; echo "Added $1"
  elif cmp -s "$tmp" "$1"; then echo "Already there: $1"
  else echo "Left alone (it differs from mine): $1"; fi
  rm -f "$tmp"
}
put infra/request-certificate.sh <<'VICBLESS_EOF'
#!/usr/bin/env bash
# Requests ONE HTTPS certificate that covers the bare domain, www and dev, then prints the DNS
# records to add at Namecheap so AWS can check that you own the domain.
# Usage: bash infra/request-certificate.sh [domain]     (default: vicbless.com)
# Safe to run again: it reuses the certificate it already made instead of creating another.
set -euo pipefail

DOMAIN="${1:-vicbless.com}"
REGION="us-east-1" # CloudFront only accepts certificates from us-east-1

ARN="$(aws acm list-certificates --region "$REGION" \
  --certificate-statuses PENDING_VALIDATION ISSUED \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" --output text)"

if [ -z "$ARN" ] || [ "$ARN" = "None" ]; then
  ARN="$(aws acm request-certificate --region "$REGION" \
    --domain-name "$DOMAIN" \
    --subject-alternative-names "www.$DOMAIN" "dev.$DOMAIN" \
    --validation-method DNS \
    --tags Key=Project,Value=vicbless-booking-platform \
    --query CertificateArn --output text)"
  echo "Requested a new certificate for $DOMAIN, www.$DOMAIN and dev.$DOMAIN."
else
  echo "Using the certificate that already exists for $DOMAIN."
fi
echo "CertificateArn: $ARN"

# The validation records take a few seconds to appear.
RECORDS=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  RECORDS="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" \
    --query "Certificate.DomainValidationOptions[].ResourceRecord.[Name,Value]" --output text)"
  if [ -n "$RECORDS" ] && ! grep -q "None" <<< "$RECORDS"; then break; fi
  RECORDS=""
  sleep 3
done
if [ -z "$RECORDS" ]; then
  echo "AWS has not produced the validation records yet. Run this script again in a minute."
  exit 1
fi

echo ""
echo "Add these at Namecheap (Domain List > Manage > Advanced DNS > Add New Record):"
echo ""
printf '  %-6s  %-34s  %s\n' "Type" "Host" "Value"
while IFS=$'\t' read -r NAME VALUE; do
  [ -z "$NAME" ] && continue
  HOST="${NAME%.}"         # drop the trailing dot
  HOST="${HOST%."$DOMAIN"}" # Namecheap wants only the part before the domain
  VALUE="${VALUE%.}"
  printf '  %-6s  %-34s  %s\n' "CNAME" "$HOST" "$VALUE"
done <<< "$RECORDS"

echo ""
echo "Keep these records forever: AWS renews the certificate by itself, but only while they exist."
echo "Then wait for the status to read ISSUED (usually a few minutes):"
echo "  aws acm describe-certificate --region $REGION --certificate-arn $ARN --query Certificate.Status --output text"
VICBLESS_EOF
put infra/dns-records.sh <<'VICBLESS_EOF'
#!/usr/bin/env bash
# Prints the DNS records to add at Namecheap once a hosting stack has been deployed.
# Usage: bash infra/dns-records.sh dev|prod [domain]     (default domain: vicbless.com)
set -euo pipefail

ENVIRONMENT="${1:-}"
DOMAIN="${2:-vicbless.com}"
case "$ENVIRONMENT" in
  dev | prod) ;;
  *)
    echo "Usage: bash infra/dns-records.sh dev|prod [domain]"
    exit 1
    ;;
esac

STACK="vicbless-frontend-$ENVIRONMENT"
TARGET="$(aws cloudformation describe-stacks --stack-name "$STACK" --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" --output text)"
if [ -z "$TARGET" ] || [ "$TARGET" = "None" ]; then
  echo "Could not read DistributionDomain from $STACK. Has it been deployed yet?"
  exit 1
fi

echo "Add these at Namecheap (Domain List > Manage > Advanced DNS > Add New Record):"
echo ""
printf '  %-6s  %-6s  %s\n' "Type" "Host" "Value"
if [ "$ENVIRONMENT" = "dev" ]; then
  printf '  %-6s  %-6s  %s\n' "CNAME" "dev" "$TARGET"
  echo ""
  echo "Then open: https://dev.$DOMAIN/?key=<your DEV_PREVIEW_KEY>"
else
  printf '  %-6s  %-6s  %s\n' "ALIAS" "@" "$TARGET"
  printf '  %-6s  %-6s  %s\n' "CNAME" "www" "$TARGET"
  echo ""
  echo "(Skip the www line if PROD_INCLUDE_WWW is false. The bare domain needs ALIAS, not CNAME.)"
fi
echo ""
echo "First delete Namecheap's default parking records for the same host, if any, or they will clash."
VICBLESS_EOF
echo
echo "Next:  AWS_PROFILE=vicbless bash infra/request-certificate.sh"
