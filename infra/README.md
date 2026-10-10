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
