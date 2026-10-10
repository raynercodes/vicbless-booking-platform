#!/usr/bin/env bash
# Vicbless: AWS hosting for the frontend (CloudFormation stack, GitHub deploy role, deploy workflow).
# Run from the REPO ROOT (the folder with .git, frontend/ and backend/):  bash add-vicbless-infra.sh
# Creates new files only. If any already exists it stops, so nothing of yours is overwritten
# (run with FORCE=1 to overwrite).
set -euo pipefail

if [ ! -d .git ] || [ ! -d frontend ] || [ ! -d backend ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git, frontend/ and backend/)."
  exit 1
fi

if [ "${FORCE:-0}" != "1" ]; then
  for f in infra/frontend-hosting.yaml infra/github-oidc-role.yaml infra/publish-site.sh .github/workflows/deploy-frontend.yml infra/README.md; do
    if [ -e "$f" ]; then echo "$f already exists. Run with FORCE=1 to overwrite."; exit 1; fi
  done
fi

mkdir -p infra .github/workflows

cat > infra/frontend-hosting.yaml <<'VICBLESS_EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Vicbless frontend hosting. A private S3 bucket behind CloudFront (origin access control),
  an optional custom domain with an ACM certificate and Route 53 records, and an optional
  preview gate that keeps a non-public environment private. Deploy in us-east-1.

Parameters:
  Environment:
    Type: String
    AllowedValues: [dev, prod]
    Description: dev adds a no-index header. Use PreviewKey to also keep it private.

  SiteDomain:
    Type: String
    Default: ''
    Description: >-
      Main domain for this environment, for example vicbless.com or dev.vicbless.com.
      Leave empty to use the default CloudFront address (xxxx.cloudfront.net).

  IncludeWww:
    Type: String
    AllowedValues: ['true', 'false']
    Default: 'false'
    Description: Also serve www.<SiteDomain>.

  HostedZoneId:
    Type: String
    Default: ''
    Description: >-
      Route 53 hosted zone that contains SiteDomain. When set, the certificate is validated
      and the DNS records are created automatically.

  CertificateArn:
    Type: String
    Default: ''
    Description: >-
      Use an existing ACM certificate (must be in us-east-1) instead of creating one.
      For when DNS is not in Route 53. The DNS records are then added by hand.

  PreviewKey:
    Type: String
    Default: ''
    NoEcho: true
    AllowedPattern: '^$|^[A-Za-z0-9_-]{16,64}$'
    Description: >-
      Optional secret that keeps the site private. Visitors open https://site/?key=<this value>
      once, which sets a cookie. Leave empty for a public site (production).

Rules:
  DomainNeedsDnsOrCertificate:
    RuleCondition: !Not [!Equals [!Ref SiteDomain, '']]
    Assertions:
      - Assert: !Not [!And [!Equals [!Ref HostedZoneId, ''], !Equals [!Ref CertificateArn, '']]]
        AssertDescription: >-
          A custom domain needs either a HostedZoneId (automatic) or a CertificateArn (manual DNS).

Conditions:
  IsDev: !Equals [!Ref Environment, dev]
  HasDomain: !Not [!Equals [!Ref SiteDomain, '']]
  HasZone: !Not [!Equals [!Ref HostedZoneId, '']]
  HasCertArn: !Not [!Equals [!Ref CertificateArn, '']]
  UseCustomDomain: !And
    - !Condition HasDomain
    - !Or [!Condition HasZone, !Condition HasCertArn]
  CreateCert: !And
    - !Condition UseCustomDomain
    - !Condition HasZone
    - !Not [!Condition HasCertArn]
  WithWww: !And
    - !Condition UseCustomDomain
    - !Equals [!Ref IncludeWww, 'true']
  CreateRecords: !And
    - !Condition UseCustomDomain
    - !Condition HasZone
  CreateRecordsWww: !And
    - !Condition CreateRecords
    - !Condition WithWww
  HasPreviewKey: !Not [!Equals [!Ref PreviewKey, '']]

Resources:
  # ---------------------------------------------------------------
  # Where the built site lives. Private: only CloudFront can read it.
  # ---------------------------------------------------------------
  SiteBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub vicbless-frontend-${Environment}-${AWS::AccountId}
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: expire-old-versions
            Status: Enabled
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
      Tags:
        - Key: Project
          Value: vicbless-booking-platform
        - Key: Environment
          Value: !Ref Environment

  OriginAccessControl:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub vicbless-${Environment}-oac
        Description: Lets CloudFront, and only CloudFront, read the site bucket
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  SiteBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref SiteBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowCloudFrontRead
            Effect: Allow
            Principal:
              Service: cloudfront.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub ${SiteBucket.Arn}/*
            Condition:
              StringEquals:
                AWS:SourceArn: !Sub arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${Distribution}
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: s3:*
            Resource:
              - !GetAtt SiteBucket.Arn
              - !Sub ${SiteBucket.Arn}/*
            Condition:
              Bool:
                aws:SecureTransport: 'false'

  # ---------------------------------------------------------------
  # Response headers: security headers always, no-index on dev.
  # ---------------------------------------------------------------
  SecurityHeaders:
    Type: AWS::CloudFront::ResponseHeadersPolicy
    Properties:
      ResponseHeadersPolicyConfig:
        Name: !Sub vicbless-${Environment}-security-headers
        SecurityHeadersConfig:
          StrictTransportSecurity:
            AccessControlMaxAgeSec: 31536000
            IncludeSubdomains: false
            Preload: false
            Override: true
          ContentTypeOptions:
            Override: true
          FrameOptions:
            FrameOption: DENY
            Override: true
          ReferrerPolicy:
            ReferrerPolicy: strict-origin-when-cross-origin
            Override: true
        CustomHeadersConfig: !If
          - IsDev
          - Items:
              - Header: X-Robots-Tag
                Value: noindex, nofollow
                Override: true
          - !Ref AWS::NoValue

  # ---------------------------------------------------------------
  # Preview gate (only when PreviewKey is set). Runs before anything is
  # served. A cookie works for video on iPhones, unlike a password prompt.
  #   no cookie, no key      -> 403 "not public yet"
  #   ?key=<secret>          -> sets a 30 day cookie and redirects to the clean address
  #   cookie matches         -> the request goes through
  # ---------------------------------------------------------------
  PreviewGate:
    Type: AWS::CloudFront::Function
    Condition: HasPreviewKey
    Properties:
      Name: !Sub vicbless-${Environment}-preview-gate
      AutoPublish: true
      FunctionConfig:
        Comment: Keeps a non-public Vicbless environment private
        Runtime: cloudfront-js-2.0
      FunctionCode: !Sub |
        function handler(event) {
          var request = event.request;
          var key = '${PreviewKey}';
          var cookies = request.cookies || {};
          if (cookies.vb_preview && cookies.vb_preview.value === key) {
            return request;
          }
          var query = request.querystring || {};
          if (query.key && query.key.value === key) {
            var rest = [];
            for (var name in query) {
              if (name !== 'key') {
                rest.push(name + '=' + query[name].value);
              }
            }
            return {
              statusCode: 302,
              statusDescription: 'Found',
              headers: {
                location: { value: request.uri + (rest.length ? '?' + rest.join('&') : '') },
                'cache-control': { value: 'no-store' }
              },
              cookies: {
                vb_preview: { value: key, attributes: 'Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=2592000' }
              }
            };
          }
          return {
            statusCode: 403,
            statusDescription: 'Forbidden',
            headers: {
              'content-type': { value: 'text/html; charset=utf-8' },
              'cache-control': { value: 'no-store' }
            },
            body: '<!doctype html><title>Vicbless preview</title><h1>Vicbless preview</h1><p>This site is not public yet.</p>'
          };
        }

  # ---------------------------------------------------------------
  # HTTPS certificate (only when the domain is in Route 53 and no certificate was supplied).
  # Must be in us-east-1 for CloudFront.
  # ---------------------------------------------------------------
  Certificate:
    Type: AWS::CertificateManager::Certificate
    Condition: CreateCert
    Properties:
      DomainName: !Ref SiteDomain
      SubjectAlternativeNames: !If
        - WithWww
        - [!Sub 'www.${SiteDomain}']
        - !Ref AWS::NoValue
      ValidationMethod: DNS
      DomainValidationOptions:
        - DomainName: !Ref SiteDomain
          HostedZoneId: !Ref HostedZoneId
        - !If
          - WithWww
          - DomainName: !Sub 'www.${SiteDomain}'
            HostedZoneId: !Ref HostedZoneId
          - !Ref AWS::NoValue

  Distribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true
        Comment: !Sub Vicbless ${Environment} site
        DefaultRootObject: index.html
        HttpVersion: http2and3
        IPV6Enabled: true
        PriceClass: PriceClass_100
        Aliases: !If
          - UseCustomDomain
          - !If
            - WithWww
            - [!Ref SiteDomain, !Sub 'www.${SiteDomain}']
            - [!Ref SiteDomain]
          - !Ref AWS::NoValue
        Origins:
          - Id: site-bucket
            DomainName: !GetAtt SiteBucket.RegionalDomainName
            OriginAccessControlId: !GetAtt OriginAccessControl.Id
            S3OriginConfig:
              OriginAccessIdentity: ''
        DefaultCacheBehavior:
          TargetOriginId: site-bucket
          ViewerProtocolPolicy: redirect-to-https
          AllowedMethods: [GET, HEAD, OPTIONS]
          CachedMethods: [GET, HEAD]
          Compress: true
          # AWS managed policy "CachingOptimized". Cache lifetimes come from the Cache-Control
          # headers that infra/publish-site.sh sets on each file.
          CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6
          ResponseHeadersPolicyId: !Ref SecurityHeaders
          FunctionAssociations: !If
            - HasPreviewKey
            - - EventType: viewer-request
                FunctionARN: !GetAtt PreviewGate.FunctionMetadata.FunctionARN
            - !Ref AWS::NoValue
        ViewerCertificate: !If
          - UseCustomDomain
          - AcmCertificateArn: !If [HasCertArn, !Ref CertificateArn, !Ref Certificate]
            SslSupportMethod: sni-only
            MinimumProtocolVersion: TLSv1.2_2021
          - CloudFrontDefaultCertificate: true

  # ---------------------------------------------------------------
  # DNS records (only when the domain is in Route 53).
  # Z2FDTNDATAQYW2 is CloudFront's fixed hosted zone id for alias records.
  # ---------------------------------------------------------------
  SiteRecords:
    Type: AWS::Route53::RecordSetGroup
    Condition: CreateRecords
    Properties:
      HostedZoneId: !Ref HostedZoneId
      RecordSets:
        - Name: !Ref SiteDomain
          Type: A
          AliasTarget:
            DNSName: !GetAtt Distribution.DomainName
            HostedZoneId: Z2FDTNDATAQYW2
        - Name: !Ref SiteDomain
          Type: AAAA
          AliasTarget:
            DNSName: !GetAtt Distribution.DomainName
            HostedZoneId: Z2FDTNDATAQYW2
        - !If
          - CreateRecordsWww
          - Name: !Sub 'www.${SiteDomain}'
            Type: A
            AliasTarget:
              DNSName: !GetAtt Distribution.DomainName
              HostedZoneId: Z2FDTNDATAQYW2
          - !Ref AWS::NoValue
        - !If
          - CreateRecordsWww
          - Name: !Sub 'www.${SiteDomain}'
            Type: AAAA
            AliasTarget:
              DNSName: !GetAtt Distribution.DomainName
              HostedZoneId: Z2FDTNDATAQYW2
          - !Ref AWS::NoValue

Outputs:
  BucketName:
    Description: Bucket the built site is uploaded to
    Value: !Ref SiteBucket
  DistributionId:
    Description: CloudFront distribution id (used to refresh the cache after a deploy)
    Value: !Ref Distribution
  DistributionDomain:
    Description: Default CloudFront address. For manual DNS, point a CNAME or ALIAS here.
    Value: !GetAtt Distribution.DomainName
  SiteUrl:
    Description: Where the site can be opened
    Value: !If
      - UseCustomDomain
      - !Sub https://${SiteDomain}
      - !Sub https://${Distribution.DomainName}
VICBLESS_EOF

cat > infra/github-oidc-role.yaml <<'VICBLESS_EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  One-time setup. The role GitHub Actions assumes (through OIDC, no stored keys) to deploy the
  Vicbless frontend hosting stack and upload the site. Deploy once by hand, in us-east-1.

Parameters:
  GitHubRepo:
    Type: String
    Default: raynercodes/vicbless-booking-platform
    Description: owner/repo of the GitHub repository. Check it matches yours exactly.
  OidcProviderArn:
    Type: String
    Default: ''
    Description: >-
      ARN of the account's GitHub OIDC provider. Leave empty to use the standard one
      (token.actions.githubusercontent.com), which already exists if another project uses OIDC.

Conditions:
  UseStandardProvider: !Equals [!Ref OidcProviderArn, '']

Resources:
  DeployRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: vicbless-github-actions-role
      Description: Deploys the Vicbless frontend hosting stack from GitHub Actions
      MaxSessionDuration: 3600
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Federated: !If
                - UseStandardProvider
                - !Sub arn:${AWS::Partition}:iam::${AWS::AccountId}:oidc-provider/token.actions.githubusercontent.com
                - !Ref OidcProviderArn
            Action: sts:AssumeRoleWithWebIdentity
            Condition:
              StringEquals:
                token.actions.githubusercontent.com:aud: sts.amazonaws.com
              StringLike:
                token.actions.githubusercontent.com:sub:
                  - !Sub repo:${GitHubRepo}:ref:refs/heads/dev
                  - !Sub repo:${GitHubRepo}:ref:refs/heads/main
                  - !Sub repo:${GitHubRepo}:environment:production
      Policies:
        - PolicyName: vicbless-frontend-deploy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: HostingStacks
                Effect: Allow
                Action: cloudformation:*
                Resource: !Sub arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/vicbless-frontend-*/*
              - Sid: ValidateTemplates
                Effect: Allow
                Action: cloudformation:ValidateTemplate
                Resource: '*'
              - Sid: SiteBuckets
                Effect: Allow
                Action: s3:*
                Resource:
                  - arn:aws:s3:::vicbless-frontend-*
                  - arn:aws:s3:::vicbless-frontend-*/*
              - Sid: CloudFront
                Effect: Allow
                Action:
                  - cloudfront:CreateDistribution
                  - cloudfront:UpdateDistribution
                  - cloudfront:DeleteDistribution
                  - cloudfront:GetDistribution
                  - cloudfront:GetDistributionConfig
                  - cloudfront:ListDistributions
                  - cloudfront:TagResource
                  - cloudfront:UntagResource
                  - cloudfront:CreateInvalidation
                  - cloudfront:GetInvalidation
                  - cloudfront:CreateOriginAccessControl
                  - cloudfront:UpdateOriginAccessControl
                  - cloudfront:DeleteOriginAccessControl
                  - cloudfront:GetOriginAccessControl
                  - cloudfront:ListOriginAccessControls
                  - cloudfront:CreateResponseHeadersPolicy
                  - cloudfront:UpdateResponseHeadersPolicy
                  - cloudfront:DeleteResponseHeadersPolicy
                  - cloudfront:GetResponseHeadersPolicy
                  - cloudfront:ListResponseHeadersPolicies
                  - cloudfront:GetCachePolicy
                  - cloudfront:ListCachePolicies
                  - cloudfront:CreateFunction
                  - cloudfront:UpdateFunction
                  - cloudfront:DeleteFunction
                  - cloudfront:DescribeFunction
                  - cloudfront:GetFunction
                  - cloudfront:PublishFunction
                  - cloudfront:ListFunctions
                Resource: '*' # CloudFront create and list actions do not support narrower resources
              - Sid: Certificates
                Effect: Allow
                Action:
                  - acm:RequestCertificate
                  - acm:DescribeCertificate
                  - acm:DeleteCertificate
                  - acm:ListCertificates
                  - acm:AddTagsToCertificate
                  - acm:ListTagsForCertificate
                Resource: '*'
              - Sid: DnsRecords
                Effect: Allow
                Action:
                  - route53:ChangeResourceRecordSets
                  - route53:ListResourceRecordSets
                  - route53:GetHostedZone
                Resource: !Sub arn:${AWS::Partition}:route53:::hostedzone/* # tighten to the vicbless.com zones if you like
              - Sid: DnsLookups
                Effect: Allow
                Action:
                  - route53:ListHostedZones
                  - route53:ListHostedZonesByName
                  - route53:GetChange
                Resource: '*'

Outputs:
  RoleArn:
    Description: Put this in the GitHub repository variable AWS_DEPLOY_ROLE_ARN
    Value: !GetAtt DeployRole.Arn
VICBLESS_EOF

cat > infra/publish-site.sh <<'VICBLESS_EOF'
#!/usr/bin/env bash
# Uploads the built site to the hosting stack's bucket and refreshes CloudFront.
# Usage: bash infra/publish-site.sh <stack-name> <built-site-folder>
set -euo pipefail

STACK="${1:?Usage: publish-site.sh <stack-name> <built-site-folder>}"
SITE="${2:?Usage: publish-site.sh <stack-name> <built-site-folder>}"

if [ ! -f "$SITE/index.html" ]; then
  echo "No index.html in $SITE. Build the site first."
  exit 1
fi

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

BUCKET="$(output BucketName)"
DISTRIBUTION_ID="$(output DistributionId)"
if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ] || [ -z "$DISTRIBUTION_ID" ] || [ "$DISTRIBUTION_ID" = "None" ]; then
  echo "Could not read BucketName and DistributionId from stack $STACK."
  exit 1
fi

# 1. Hashed files first. Their names change when their content does, so they can be cached for a year.
#    Old ones are left in place on purpose, so a visitor holding an older page still finds its files.
if [ -d "$SITE/assets" ]; then
  aws s3 sync "$SITE/assets" "s3://$BUCKET/assets" --cache-control "public,max-age=31536000,immutable"
fi

# 2. Media keeps a fixed name, so it is cached for a day only.
if [ -d "$SITE/media" ]; then
  aws s3 sync "$SITE/media" "s3://$BUCKET/media" --cache-control "public,max-age=86400" --delete
fi

# 3. Everything else (index.html) goes last and is never cached, so nobody is sent a page that
#    points at files which are not uploaded yet.
aws s3 sync "$SITE" "s3://$BUCKET" --exclude "assets/*" --exclude "media/*" --cache-control "no-cache" --delete

aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/index.html" "/media/*" > /dev/null

echo "Published $SITE to s3://$BUCKET and refreshed CloudFront ($DISTRIBUTION_ID)."
VICBLESS_EOF

cat > .github/workflows/deploy-frontend.yml <<'VICBLESS_EOF'
name: Deploy frontend

# dev:  every push to the dev branch that touches the frontend or infra deploys straight away.
# prod: manual only, from main. It shows the plan first, then waits for approval on the
#       "production" GitHub environment, then applies it and publishes the site.
on:
  push:
    branches: [dev]
    paths:
      - 'frontend/**'
      - 'infra/frontend-hosting.yaml'
      - 'infra/publish-site.sh'
      - '.github/workflows/deploy-frontend.yml'
  workflow_dispatch:
    inputs:
      target_environment:
        description: Where to deploy (prod only runs from main)
        type: choice
        options: [dev, prod]
        default: dev

permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy-frontend-${{ inputs.target_environment || 'dev' }}
  cancel-in-progress: false

env:
  AWS_REGION: us-east-1

jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: frontend/package-lock.json
      - run: npm ci
      - run: npm test
      - run: npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: site-dist
          path: frontend/dist
          if-no-files-found: error

  # ------------------------------------------------------------
  # DEV: deploys on push, no approval.
  # ------------------------------------------------------------
  deploy-dev:
    needs: build
    if: github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.target_environment == 'dev')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: site-dist
          path: dist
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - name: Deploy the hosting stack (does nothing if it is already up to date)
        env:
          DEV_DOMAIN: ${{ vars.DEV_DOMAIN }}
          DEV_HOSTED_ZONE_ID: ${{ vars.DEV_HOSTED_ZONE_ID }}
          DEV_PREVIEW_KEY: ${{ secrets.DEV_PREVIEW_KEY }}
        run: |
          aws cloudformation deploy \
            --stack-name vicbless-frontend-dev \
            --template-file infra/frontend-hosting.yaml \
            --parameter-overrides \
              Environment=dev \
              SiteDomain="$DEV_DOMAIN" \
              HostedZoneId="$DEV_HOSTED_ZONE_ID" \
              PreviewKey="$DEV_PREVIEW_KEY" \
            --no-fail-on-empty-changeset
      - name: Publish the site
        run: bash infra/publish-site.sh vicbless-frontend-dev dist
      - name: Print the dev address
        run: |
          URL=$(aws cloudformation describe-stacks --stack-name vicbless-frontend-dev --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
          echo "Dev site: $URL (open it once with ?key=<your preview key> on each device)"

  # ------------------------------------------------------------
  # PROD step 1: show the plan. Changes nothing.
  # ------------------------------------------------------------
  plan-prod:
    needs: build
    if: github.event_name == 'workflow_dispatch' && inputs.target_environment == 'prod' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    outputs:
      has_changes: ${{ steps.create-changeset.outputs.has_changes }}
      changeset_type: ${{ steps.changeset-type.outputs.type }}
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - name: Work out whether the stack is new or an update
        id: changeset-type
        run: |
          STATUS=$(aws cloudformation describe-stacks --stack-name vicbless-frontend-prod --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")
          case "$STATUS" in
            NOT_FOUND|DELETE_COMPLETE|REVIEW_IN_PROGRESS|ROLLBACK_COMPLETE) echo "type=CREATE" >> "$GITHUB_OUTPUT" ;;
            *) echo "type=UPDATE" >> "$GITHUB_OUTPUT" ;;
          esac
      - name: Create the changeset (applies nothing yet)
        id: create-changeset
        env:
          PROD_DOMAIN: ${{ vars.PROD_DOMAIN }}
          PROD_INCLUDE_WWW: ${{ vars.PROD_INCLUDE_WWW }}
          PROD_HOSTED_ZONE_ID: ${{ vars.PROD_HOSTED_ZONE_ID }}
          PROD_CERTIFICATE_ARN: ${{ vars.PROD_CERTIFICATE_ARN }}
        run: |
          jq -n \
            --arg domain "$PROD_DOMAIN" \
            --arg www "${PROD_INCLUDE_WWW:-false}" \
            --arg zone "$PROD_HOSTED_ZONE_ID" \
            --arg cert "$PROD_CERTIFICATE_ARN" \
            '[
              {ParameterKey: "Environment", ParameterValue: "prod"},
              {ParameterKey: "SiteDomain", ParameterValue: $domain},
              {ParameterKey: "IncludeWww", ParameterValue: $www},
              {ParameterKey: "HostedZoneId", ParameterValue: $zone},
              {ParameterKey: "CertificateArn", ParameterValue: $cert},
              {ParameterKey: "PreviewKey", ParameterValue: ""}
            ]' > params.json

          aws cloudformation create-change-set \
            --stack-name vicbless-frontend-prod \
            --change-set-name gha-${{ github.run_id }} \
            --change-set-type ${{ steps.changeset-type.outputs.type }} \
            --template-body file://infra/frontend-hosting.yaml \
            --parameters file://params.json

          aws cloudformation wait change-set-create-complete \
            --stack-name vicbless-frontend-prod \
            --change-set-name gha-${{ github.run_id }} || true

          STATUS=$(aws cloudformation describe-change-set --stack-name vicbless-frontend-prod --change-set-name gha-${{ github.run_id }} --query "Status" --output text)
          REASON=$(aws cloudformation describe-change-set --stack-name vicbless-frontend-prod --change-set-name gha-${{ github.run_id }} --query "StatusReason" --output text)

          if [ "$STATUS" == "FAILED" ]; then
            if [[ "$REASON" == *"didn't contain changes"* ]] || [[ "$REASON" == *"No updates are to be performed"* ]]; then
              echo "No infrastructure changes. Prod already matches the template."
              echo "has_changes=false" >> "$GITHUB_OUTPUT"
              aws cloudformation delete-change-set --stack-name vicbless-frontend-prod --change-set-name gha-${{ github.run_id }}
            else
              echo "The changeset failed: $REASON"
              exit 1
            fi
          else
            echo "has_changes=true" >> "$GITHUB_OUTPUT"
          fi
      - name: Print the plan
        if: steps.create-changeset.outputs.has_changes == 'true'
        run: |
          aws cloudformation describe-change-set \
            --stack-name vicbless-frontend-prod \
            --change-set-name gha-${{ github.run_id }} \
            --query "Changes[].{Action:ResourceChange.Action,Resource:ResourceChange.LogicalResourceId,Type:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}" \
            --output table

  # ------------------------------------------------------------
  # PROD step 2: waits for approval, applies the plan, publishes the site.
  # ------------------------------------------------------------
  deploy-prod:
    needs: [plan-prod, build]
    if: github.event_name == 'workflow_dispatch' && inputs.target_environment == 'prod' && github.ref == 'refs/heads/main' && success()
    runs-on: ubuntu-latest
    environment: production # pauses here until a reviewer approves (set up in repo Settings, Environments)
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: site-dist
          path: dist
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - name: Apply the changeset (only if there is something to apply)
        if: needs.plan-prod.outputs.has_changes == 'true'
        run: |
          aws cloudformation execute-change-set \
            --stack-name vicbless-frontend-prod \
            --change-set-name gha-${{ github.run_id }}

          if [ "${{ needs.plan-prod.outputs.changeset_type }}" == "CREATE" ]; then
            aws cloudformation wait stack-create-complete --stack-name vicbless-frontend-prod
          else
            aws cloudformation wait stack-update-complete --stack-name vicbless-frontend-prod
          fi
      - name: Publish the site
        run: bash infra/publish-site.sh vicbless-frontend-prod dist
      - name: Print the live address
        run: |
          URL=$(aws cloudformation describe-stacks --stack-name vicbless-frontend-prod --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
          echo "Prod site: $URL"
VICBLESS_EOF

cat > infra/README.md <<'VICBLESS_EOF'
# Hosting the frontend on AWS

What this builds, per environment (`dev` and `prod`, separate stacks):

- a private S3 bucket holding the built site
- CloudFront in front of it (HTTPS only, HTTP/2 and 3, security headers)
- optionally: your own domain, with the certificate and DNS records made for you
- on dev: a no-index header, and an optional preview gate so only people with the link can see it

Everything deploys in **us-east-1** (CloudFront certificates must live there).

## One-time setup

**1. Create the deploy role** (GitHub signs in with OIDC, no stored keys). If another project of yours
already uses GitHub OIDC in this account, the provider exists and this just adds a role.

```bash
aws cloudformation deploy \
  --stack-name vicbless-github-oidc \
  --template-file infra/github-oidc-role.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --parameter-overrides GitHubRepo=raynercodes/vicbless-booking-platform   # check this is your exact owner/repo
```

Copy the `RoleArn` output.

**2. In GitHub, Settings > Secrets and variables > Actions:**

| Name | Kind | Value |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | variable | the `RoleArn` from step 1 |
| `DEV_PREVIEW_KEY` | secret | a long random string, 16 to 64 letters, digits, `-` or `_` |
| `DEV_DOMAIN` | variable | leave empty at first (see "No DNS yet"), later `dev.vicbless.com` |
| `DEV_HOSTED_ZONE_ID` | variable | leave empty at first, later the zone id for `dev.vicbless.com` |
| `PROD_DOMAIN` | variable | `vicbless.com` (when you are ready for prod) |
| `PROD_INCLUDE_WWW` | variable | `true` |
| `PROD_HOSTED_ZONE_ID` | variable | the zone id, if DNS is in Route 53 |
| `PROD_CERTIFICATE_ARN` | variable | only if DNS is NOT in Route 53 |

Make a random preview key with: `openssl rand -hex 16`

**3. Settings > Environments > New environment: `production`**, and add yourself as a required reviewer.
That is the approval step before anything reaches prod.

## No DNS yet: deploy and test straight away

Leave `DEV_DOMAIN` and `DEV_HOSTED_ZONE_ID` empty and push to `dev`. The stack uses the default
CloudFront address. The workflow prints it at the end. Open it once on each device like this:

```
https://dxxxxxxxxxxxx.cloudfront.net/?key=<your DEV_PREVIEW_KEY>
```

That sets a 30 day cookie and takes you to the normal address. Anyone without the link sees
"This site is not public yet." Send that link to Vic.

## dev.vicbless.com (safe, touches nothing existing)

Make a hosted zone for just the `dev` subdomain, then delegate to it. Nothing else on
`vicbless.com` changes, so existing email and records are untouched.

```bash
aws route53 create-hosted-zone --name dev.vicbless.com --caller-reference "$(date +%s)"
```

1. Note the zone id and the four name servers it returns.
2. At whoever hosts the DNS for `vicbless.com`, add an **NS** record named `dev` with those four name servers.
3. Set `DEV_DOMAIN=dev.vicbless.com` and `DEV_HOSTED_ZONE_ID=<zone id>` and push to `dev`.
   The certificate and records are created for you (first time can take a few minutes while the certificate validates).

## vicbless.com (prod), decide before you do this

A bare domain (`vicbless.com`, no `www`) can only point at CloudFront with an **ALIAS** record. Route 53
supports that. Many other DNS hosts do not.

- **Option A, move DNS to Route 53 (simplest, fully automatic).** BEFORE you change the name servers at the
  registrar, copy every existing record (especially **MX and TXT records, which carry email**) into the new
  zone. Switching name servers without copying them breaks email.
- **Option B, keep DNS where it is.** Request the certificate yourself in ACM (us-east-1), add its validation
  CNAME at your DNS host, set `PROD_CERTIFICATE_ARN`, leave `PROD_HOSTED_ZONE_ID` empty, and after the first
  deploy point your DNS at the `DistributionDomain` output (an ALIAS/ANAME for the bare domain, a CNAME for `www`).

Then run **Actions > Deploy frontend > Run workflow > prod** from `main`. It prints the plan, waits for your
approval, applies it, and publishes the site.

## Cache rules (so updates show up)

`infra/publish-site.sh` sets these on upload: hashed files in `assets/` are cached for a year, `media/` for a
day, and `index.html` is never cached. After each deploy it refreshes `/index.html` and `/media/*` in CloudFront.

## Good to know

- The S3 bucket is kept if you ever delete a stack (`DeletionPolicy: Retain`), so the site files are never lost by accident.
  Delete the bucket by hand if you really want it gone.
- The preview key sits inside the CloudFront function's code, which anyone with access to your AWS account can read.
  It is a privacy gate for a test site, not a security boundary. Prod has no gate.
- A Content-Security-Policy header is not set yet. The site loads Google Fonts and has one small inline script,
  so a policy needs a little care. A good thing to add before launch.
VICBLESS_EOF

chmod +x infra/publish-site.sh

echo ""
echo "Files written. Checking the templates if cfn-lint is installed..."
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint infra/frontend-hosting.yaml infra/github-oidc-role.yaml && echo "cfn-lint: no problems"
else
  echo "(cfn-lint not installed. To check the templates: pip install cfn-lint, then cfn-lint infra/*.yaml)"
fi

echo ""
echo "Running the frontend tests..."
(cd frontend && npm test)

echo ""
echo "Next: read infra/README.md, then follow the one-time setup."
echo ""
echo "Git commands (not run for you):"
echo "  git add -A"
echo "  git commit -m \"Add AWS hosting: CloudFormation stack, deploy role, deploy workflow\""
echo "  git push"
