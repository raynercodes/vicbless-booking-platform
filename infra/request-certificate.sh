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
