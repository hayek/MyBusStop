# BusBus — Backend hosting with a fixed egress IP (for MOT SIRI allow-list)

Research date: 2026-09-17. Research only: no sign-ups, purchases or account creation were made.
Companion to `israel-app-backends.md` (why we need a static IP: MOT SIRI-SM key is bound to one static IP registered on the form) and `transit-apis.md`.

Legend: **[V]** verified today on the provider's official pricing/docs/terms page (URL given). **[U]** unverified (page could not be fetched, or the fact is not stated on an official page). Nothing below is filled from memory; if it isn't tagged [V] with a URL, treat it as unconfirmed.

Workload assumed throughout: 1 small always-on VM/container; ~few hundred HTTPS requests/min to `moran.mot.gov.il` (10–200 KB responses → at most ~1–3 GB/day *inbound*, much less outbound); daily 212 MB GTFS download + import needing ~1–2 GB RAM briefly and a few GB disk; low-traffic JSON API to the app. Egress to the internet is therefore small (well under 100 GB/month) — bandwidth caps matter little; **RAM (≥2 GB comfortable, 1 GB marginal) and a guaranteed-static IPv4 matter most.**

---

## Part A — Free tiers

### A1. Oracle Cloud Infrastructure (OCI) Always Free

**Free resources** [V] https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- AMD `VM.Standard.E2.1.Micro`: "1/8th of an OCPU", "1 GB" memory, "up to two Always Free VM instances", "Includes one VNIC with one public IP address and up to 50 Mbps network bandwidth via the internet."
- Arm `VM.Standard.A1.Flex`: "the first 1,500 OCPU hours and 9,000 GB hours per month for free" = "2 OCPUs and 12 GB of memory" for Always Free tenancies, allocatable flexibly (e.g. one 2-OCPU/12 GB VM, or 1 OCPU/6 GB).
- Block Volume: "a total of 200 GB of Block Volume storage, and five volume backups". Must be created in the home region.
- Outbound data: "10 TB per month of outbound data".
- "You must create the Always Free compute instances in your home region."

**Idle reclamation policy** [V] same URL — "Idle Always Free compute instances may be reclaimed by Oracle. Oracle will deem … instances as idle if, during a 7-day period, the following are true: CPU utilization for the 95th percentile is less than 20%; Network utilization is less than 20%; Memory utilization is less than 20% (applies to A1 shapes only)". Note the conditions are ANDed — a poller hitting MOT every 15–30 s and a daily GTFS import will very likely keep CPU or memory above 20%, but a 1/8-OCPU micro VM sitting mostly idle is at real risk. Mitigation: use the A1 shape (memory >20% of 6–12 GB is easy to hold with an in-memory GTFS/Redis) or keep CPU busy. [V for the policy; the mitigation is our inference]

**Trial / account** [V] https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm
- "$300 of cloud credits that are valid for up to 30 days".
- "most users need a mobile phone number and a credit card to create an account. Your credit card will not be charged unless you upgrade your account."
- "After your trial ends, your account remains active. There is no interruption to the availability of the Always Free Resources you have provisioned."
- "During sign-up, choose the home region carefully. You can provision Always Free Autonomous AI Databases and compute instances only in the home region." (Home region cannot be changed.)
- A1 capacity gotcha: "If you have more OCI Ampere A1 Compute instances provisioned than are available for an Always Free tenancy, all existing OCI Ampere A1 Compute instances are disabled and then deleted after 30 days, unless you upgrade to a paid account."
- Payment methods [V] https://www.oracle.com/cloud/free/ (FAQ): "We accept credit cards and debit cards that function like credit cards. We do not accept debit cards with a PIN or virtual, single-use, or prepaid cards." Also: "Accounts left idle for 30 days or more may be deemed abandoned and become eligible for suspension or termination."

**Is the public IP static?** [V] https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingpublicIPs.htm
- Ephemeral public IP: "The object is temporary and exists only for the lifetime of the instance." "When you stop an instance, its ephemeral public IPs remain assigned to the instance." Deleted only when the VNIC/instance is terminated.
- **Reserved public IP**: "The object is persistent and exists beyond the lifetime of the instance it's assigned to. You can unassign it and then reassign it to another instance whenever you like." Deleted "Never. Exists until you delete it." Limits: "Two per VM instance", "You can create 50 per region".
- ⇒ Use a **reserved** public IP on the VM: guaranteed static and survives rebuilds. Whether reserved public IPs carry a charge on Always Free: see A1 pricing note below.

**Israel region** [V] https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm — "Israel Central (Jerusalem) | il-jerusalem-1 | Jerusalem, Israel | MTZ | OC1 | 1" exists as a commercial region (1 AD). Nearby: eu-frankfurt-1, eu-milan-1, eu-amsterdam-1, eu-paris-1, eu-marseille-1, eu-madrid-1, eu-zurich-1, eu-stockholm-1, me-jeddah-1, me-abudhabi-1, me-dubai-1. Whether Jerusalem can be picked as the *home region* for a new Free Tier account, and whether A1 capacity is available there, is **[U]** (only visible in the sign-up form; not documented).

**Fit**: A1 2 OCPU / 12 GB RAM handles the GTFS import trivially; 200 GB block storage is ample. Cost: **$0/month** if it stays within Always Free (see pricing check for reserved IP below). Main risks: A1 "Out of capacity" at provisioning time (widely reported, [U] — not an official statement), idle reclamation, home-region lock-in, card-verification failures at sign-up (anecdotal, [U]).

### A2. Google Cloud free tier (e2-micro)

**Free tier** [V] https://docs.cloud.google.com/free/docs/free-cloud-features
- "1 non-preemptible e2-micro VM instance per month in one of the following US regions: Oregon: us-west1. Iowa: us-central1. South Carolina: us-east1." (**US only — no Tel Aviv**.)
- "30 GB-months standard persistent disk", "1 GB of outbound data transfer from North America to all region destinations (excluding China and Australia) per month."
- Free Trial: "$300 in Welcome credit to spend over 90 days", "During the sign up, you must provide a credit card or other payment method".
- e2-micro CPU: "e2-micro sustains 2 vCPUs, each for 12.5% of CPU time totaling 25% CPU time" [V] https://docs.cloud.google.com/compute/docs/general-purpose-machines. RAM (1 GB) not captured on a fetched page today [U] — marginal for a 212 MB GTFS import; would need swap/streaming import.

**External IP is NOT free on the free tier** [V] https://cloud.google.com/vpc/network-pricing
- "Static and ephemeral IP addresses in use on standard VM instances — $0.005 / 1 hour". "Static IP address (assigned but unused) — $0.01 / 1 hour". "Static and ephemeral IP addresses used by Cloud NAT — $0.005 / 1 hour".
- "Free Tier: Both static and ephemeral IP addresses assigned to standard VM instances are offered with a free tier. This free usage is limited to one hour per month per account."
- ⇒ A "free" e2-micro with a public IPv4 costs ≈ 730 h × $0.005 = **$3.65/month** for the IP alone (plus Cloud Platform SKU currency differences). The IP *is* guaranteed static if you reserve a static external address ("Google Cloud considers a static external IP address as in use if it is associated with a VM instance whether the instance is running or stopped").

### A3. AWS Free Tier (2025+ model)

[V] https://aws.amazon.com/free/
- "$100 in credits immediately. As you explore key services, you can earn up to $100 more. That's up to $200 over 6 months". "The account closes on its own 6 months after you open it or when your credits run out, whichever comes first." (Free plan.) Paid plan: "access to all AWS services", pay-as-you-go, also up to $200 credits.
- "30+ AWS services are always free within monthly usage limits on both the Free and Paid plans."
- ⇒ There is no longer a 12-month free EC2 tier for new accounts; the free plan is a **6-month credit-limited sandbox that auto-closes** — unsuitable for an always-on production backend unless you go to the Paid plan.

**Public IPv4 charge** [V] https://aws.amazon.com/vpc/pricing/ — "Hourly charge for In-use Public IPv4 Address $0.005" and "Hourly charge for Idle Public IvP4 Address $0.005" ⇒ ≈ **$3.65/month** per IPv4 (Elastic IP or auto-assigned). NAT Gateway (us-east-2 example on the page): "$0.045 per hour" + "$0.045" per GB processed ⇒ ≈ **$32.85/month + data** — far too expensive for this workload.

### A4. Azure free account

[V] https://azure.microsoft.com/en-us/pricing/purchase-options/azure-account
- "$200 credit to use on Azure services within 30 days"; "Free monthly amounts of 20+ popular services for 12 months" incl. "750 hours each of B1s, B2pts v2 (Arm-based), and B2ats v2 (AMD-based) burstable VMs".
- "All you need is a phone number, a credit card or a debit card (non-prepaid), and a Microsoft account or a GitHub account."
- Public IP address pricing and Israel Central availability: see A4 follow-up below.

### A5. Fly.io

[V] https://fly.io/docs/about/pricing/
- "Dedicated IPv4 addresses are $2/mo." (this is the *inbound* anycast IPv4 for your app, not egress).
- **Static egress IP: "$0.005 per hour (~$3.60/month)"** per machine.
- Machines (Amsterdam shown): shared-cpu-1x 256 MB "$2.02"/mo, 1 GB "$5.92"/mo, 2 GB "$11.11"/mo. Volumes "$0.15/GB per month". Outbound: "$0.02 per GB" NA/EU.
- No general free tier is listed on the pricing page (only "first 10 single hostname certificates are free" and "First 10GB free each month" of volume snapshots). ⇒ **Not free.**
- Estimated monthly (1 GB machine + static egress IP + 5 GB volume): 5.92 + 3.60 + 0.75 ≈ **$10.27** (2 GB machine: ≈ $15.46). Behaviour of the static egress IP (per-machine, persistence) — see A5 follow-up.

### A6. Render

[V] https://render.com/docs/static-outbound-ip-addresses
- "Render services send outbound traffic through specific sets of IP ranges depending on their region." "Outbound IP ranges are shared across all services in the same region." A service "might use any IP address within its associated ranges."
- ⇒ On the standard plans you get a **fixed regional IP range (shared with all Render customers)**, not a dedicated IP. MOT's form asks for *one* static IP, so a shared range is a poor fit (you'd have to register several IPs and MOT may refuse). Render mentions "You can now add dedicated outbound IPs to your workspace" — pricing/plan on the dedicated-IP page (see follow-up). Free web services spin down on idle (see follow-up).

### A7. Railway

[V] https://docs.railway.com/reference/static-outbound-ips
- "Customers on the Pro plan can enable Static Outbound IPs for any service they wish." Enabled per service; the service gets a set of IPv4 addresses "tied to the region your service is deployed in" (three IPs "for HA load balancing"); redeploy required after toggling.
- ⇒ Not free (Pro plan). Pro plan price: see follow-up. Note: **three** egress IPs per service — MOT would have to allow-list all three.

**Follow-ups to A1–A7 (fetched later today)**

- A1 Oracle — reserved public IP pricing: the OCI price list https://www.oracle.com/cloud/price-list/ and networking pricing https://www.oracle.com/cloud/networking/pricing/ (both fetched via curl, 350 KB) contain **no line item for public/reserved IP addresses** at all (searched "Public IP", "Reserved Public IP", "NAT Gateway": absent). Networking items listed: "Inbound Data Transfer — Free", "Outbound Data Transfer – Originating in Middle East and Africa – First 10 TB / Month — Free". ⇒ No published charge for a reserved public IP [V by absence]; Always Free explicitly includes "one VNIC with one public IP address". A1 hourly price beyond free (for cost if we exceed 2 OCPU/12 GB) is JS-rendered on https://www.oracle.com/cloud/compute/pricing/ and could not be read [U].
- A2 GCP — e2-micro CPU: "e2-micro sustains 2 vCPUs, each for 12.5% of CPU time totaling 25% CPU time" (bursts 30 s) [V] https://docs.cloud.google.com/compute/docs/general-purpose-machines. Memory (1 GB) is not on that page excerpt [U-today, well known]. **Tel Aviv (me-west1) exists** [V] (listed in region selectors on https://cloud.google.com/vpc/network-pricing and https://cloud.google.com/run/pricing) but e2 prices for me-west1 are JS-rendered and could not be extracted [U]; the free e2-micro is US-only anyway.
- A3 AWS — Public IPv4 charge confirmed in the Feb-2024 announcement [V] https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/ : "$0.005 per IP per hour for all public IPv4 addresses", "Effective February 1, 2024", and "The AWS Free Tier for EC2 will include 750 hours of public IPv4 address usage per month for the first 12 months" — but note the 12-month free tier described there is the *legacy* model; new accounts get the 6-month credit plan (A3). Lightsail: "Lightsail's short-term free trial offers have been replaced by the AWS Free Tier" [V] https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-frequently-asked-questions-faq-billing-and-account-management.html.
- A4 Azure — official retail price API (https://prices.azure.com/api/retail/prices, queried today for `armRegionName eq 'israelcentral'`): "IP Addresses | Standard | Standard IPv4 Static Public IP | 0.005 USD/hour" (≈ **$3.65/mo**), "Basic IPv4 Static Public IP | 0.0036/hour" (Basic SKU; retirement not checked [U]). B1s (1 vCPU/1 GiB) $0.012/h ≈ $8.76/mo; B2ats_v2 (2 vCPU/1 GiB) $0.0107/h ≈ $7.81/mo; B1ms (1 vCPU/2 GiB) $0.024/h ≈ $17.52/mo; Standard SSD E4 (32 GB) $2.88/mo; internet egress "Standard Data Transfer Out" $0 for first 100 GB then $0.08/GB [V]. Same IP price in westeurope. Whether the free account's 12-month "750 h B1s" also waives the public IP charge is not stated [U]. A Standard-SKU public IP is static by definition (allocation method static) [V per SKU name].
- A5 Fly.io — app-scoped static egress IP [V] https://fly.io/docs/networking/egress-ips/ : "Each app-scoped IPv4 static egress address costs $3.60/mo, billed hourly. IPv6 addresses are allocated alongside IPv4 and are not billed separately." "App-scoped egress IPs are only released when you explicitly run fly ips release-egress. They persist across Machine destruction and deployments." Allocated per app **per region** (`fly ips allocate-egress --app <app> -r <region>`); "Each static egress IP can support up to 64 Machines". ⇒ Guaranteed static, single IPv4 — good fit for the MOT form. **Regions**: no Israel/Middle East; nearest fra, ams, cdg, lhr [V] https://fly.io/docs/reference/regions/.
- A6 Render — Dedicated IPs: "$100/month for each IP set", "Pro workspaces and higher", "Each dedicated IP set includes three IPv4 addresses in a single region" [V] https://render.com/changelog/add-dedicated-outbound-ips-to-your-workspace and https://render.com/docs/dedicated-ips ("A service's outbound requests might use any IP in its assigned set"). Free web services: "spins down a Free web service that goes 15 minutes without receiving any inbound traffic", "750 Free instance hours to each workspace per calendar month" [V] https://render.com/docs/free ⇒ a free service cannot run a 24/7 poller. Pro workspace price is JS-rendered on https://render.com/pricing [U]. **Verdict: not free, $100+/mo for a static IP — reject.**
- A7 Railway — [V] https://railway.com/pricing : Hobby "$5/month" incl. "$5 of monthly usage credits"; Pro "$20/month per workspace, including $20 of monthly usage credits"; usage "$10 per GB" RAM-month, "$20 per vCPU"-month, "$0.05 per GB" egress, volumes "$0.15 per GB"-month; trial "$5 one-time credit (30 days)", "No credit card required". Static outbound IPs need **Pro** ⇒ ≈ $20/mo + usage above $20 (a 1 vCPU/1 GB service ≈ $30 → ~$30/mo total, 3 egress IPs to register). Not free; workable but pricier than a VPS.

### A8. Koyeb

[V] https://www.koyeb.com/docs/faqs/general — "We do not currently provide a list of static outbound IP addresses that your Services may be deployed to." Ranges can be looked up via `outbound-ips-region-<REGION_ID>.infra.prod.koyeb.com` but "IP addresses may be added or removed from the pool without notice." Free tier [V] https://www.koyeb.com/docs/faqs/pricing : "One free web Service in the Frankfurt or Washington, D.C. regions with 512MB of RAM, 0.1 vCPU, and 2GB of SSD", "100GB of outbound bandwidth per month for free". Pricing page lists "Advanced networking with direct IP" as an Enterprise feature [V] https://www.koyeb.com/pricing. **Verdict: no static egress IP — reject.**

### A9. Northflank

[V] https://northflank.com/docs/v1/application/network/configure-egress-ips — "Egress IPs provide a dedicated, static public IP address for outbound traffic from selected workloads"; provisioning mode "Dedicated (provisions an isolated IP for your team)"; region locked after creation; single IP shown once active. Pricing of the egress IP is **not on the docs page nor the pricing page** [U]. Pricing page [V] https://northflank.com/pricing : free sandbox "Always-on-compute – no sleeping :)" with "2× free services, 1× free database, 2× free cron jobs"; paid nf-compute-10 (0.1 vCPU/256 MB) "$2.70/month", nf-compute-20 (0.2 vCPU/512 MB) "$5.40/month", nf-compute-100-2 (1 vCPU/2 GB) "$24.00/month"; storage "$0.15 / GB / month"; egress "$0.06 / GB". **Verdict: has a true dedicated egress IP, but its price is unpublished [U] — ask sales before relying on it. Free services are too small (RAM) for the GTFS import.**

### A10. Cloudflare Workers

- Workers docs (limits page) do not mention egress/static IPs at all [V] https://developers.cloudflare.com/workers/platform/limits/. The IP-ranges page says "Cloudflare uses 172.64.0.0/13 … as public egress IP space" and "Static IP addresses: Cloudflare sets static IP addresses for your domain. For more details, contact your account team" — this is about proxying your domain, not Worker `fetch()` egress [V] https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/.
- "Dedicated egress IPs" exist only in **Cloudflare One / Zero Trust** (for WARP client/Gateway traffic; "contact your account team") [V] https://developers.cloudflare.com/cloudflare-one/traffic-policies/egress-policies/dedicated-egress-ips/ — not applicable to Workers.
- Community threads on the topic (t/757906, t/911150) returned 403 to automated fetch [U].
- **Verdict: no fixed egress IP for Workers — reject.** (Also, a Worker cannot hold a 15–30 s polling loop; it would need Cron Triggers, whose granularity we did not verify [U].)

### A11. Deno Deploy

[V] https://deno.com/deploy/pricing — Free plan "1M" requests, "20GiB" egress, "10 hr" active CPU, "150 GiB-hr" memory; Pro "$20/month". **No mention of static/dedicated/egress IPs anywhere on the pricing page** [V]. The reference docs URL we tried (https://docs.deno.com/deploy/reference/) returned 404 [U]. Third-party (Supabase) docs state Edge Functions "run on Deno Deploy with dynamic, unpublished outbound IPs" [U — not Deno's own statement]. **Verdict: reject.**

### A12. Vercel

[V] https://vercel.com/docs/networking/static-ips — "Static IPs are priced at $100/month per project for Pro plus Private Data Transfer"; "Static IP addresses are shared across a small group of customers in the same region"; a "NAT gateway" provides "static IP pairs". Secure Compute (dedicated VPC, "A pair of dedicated IP addresses") is "available as an Enterprise feature. Contact your Vercel account team for pricing"; "Private Data Transfer is billed at $0.15/GB" [V] https://vercel.com/docs/networking/secure-compute. **Verdict: $100+/mo and function-based (no always-on poller) — reject.**

### A13. Heroku

[V] https://www.heroku.com/pricing/ — no free tier; Eco "$5"/mo (sleeps after 30 min inactivity), Basic "$7"/mo 0.5 GB, Standard-1X "$25"/mo 0.5 GB. Stable outbound IPs exist only in **Private Spaces** ("All outbound traffic from apps in a Private Space originate from a small, stable list of IP addresses dedicated to the space"; "available only for verified Heroku Teams and Heroku Enterprise") [V] https://devcenter.heroku.com/articles/private-spaces ; "the four stable outbound IP addresses are not changed after the Private Space is created … only three of them are in active use at a time" [V] https://help.heroku.com/F64LBHAB/... . Private Space pricing not on the fetched pages [U]. QuotaGuard Static add-on has a "Starter Free" plan with **250 requests/month** and "100 MB" bandwidth [V] https://elements.heroku.com/addons/quotaguardstatic — useless at our volume. **Verdict: reject.**

### A14. Other "free with fixed IP" candidates found

- **Vultr** exposes a plan `vc2-1c-0.5gb-free` (1 vCPU, 512 MB, 10 GB, 0 GB bandwidth, $0/mo, not offered in Tel Aviv) in its public plans API [V] https://api.vultr.com/v2/plans — eligibility/conditions are not documented on the pages we fetched [U]. 512 MB is too small for the GTFS import anyway.
- **Kamatera** "free 30-day trial … services worth up to $100 on 1 server" [V] https://www.kamatera.com/pricing/ — trial only.
- **Northflank** free always-on services (A9) — egress IP price unknown [U].
- **Fixie** (static-IP proxy) "tricycleFree — 500 requests — $0/month" [V] https://usefixie.com/pricing — useless at hundreds of requests/minute.
- No other genuinely free always-on option with a guaranteed static IPv4 was found besides Oracle Always Free.

---

## Part B — Cheap VPS (Europe / global)

Monthly costs below = smallest plan that comfortably fits (≥2 GB RAM preferred) + IPv4 + included disk; egress is negligible for us on every provider listed (all include ≥500 GB or unlimited/fair-use).

### B1. Hetzner Cloud (Germany/Finland; also US, Singapore)
- Plans (effective 15 Jun 2026, "Monthly price excl. IPv4 in €", excl. VAT) [V] https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ : **CX23 €0.0088/h / €5.49/mo** (Germany/Finland), CX33 €8.49, **CAX11 (Arm) €5.99**, CAX21 €10.49. Specs from https://www.hetzner.com/cloud/cost-optimized/ [V]: CX23 "2" vCPU, "4 GB" RAM, "40 GB NVMe"; CAX11 same; CX33/CAX21 4 vCPU/8 GB/80 GB; "Traffic inclusive 20 TB" (EU). (The older press release https://www.hetzner.com/pressroom/new-cx-plans/ lists the superseded CX22 at €3.79 incl. IPv4 — no longer current.)
- **Primary IPv4: "€ 0.50 / mo" (€0.0008/h), "excl. VAT"; IPv6 free** [V] https://docs.hetzner.com/cloud/servers/primary-ips/overview . A Primary IP is a standalone resource that "can be created … without assigning them to a cloud server" and re-assigned ⇒ **guaranteed static** [V].
- **Total: CX23 + IPv4 = €5.99/mo excl. VAT (2 vCPU / 4 GB / 40 GB / 20 TB).** Israeli customers: VAT handling depends on the billing country [U].
- Gotcha observed today: the cost-optimized page rendered every plan as "This product is currently unavailable" for our fetch [V observed; may be geo/JS artefact or real capacity — U]. Locations: Falkenstein, Nuremberg, Helsinki, Hillsboro, Ashburn, Singapore [V] https://www.hetzner.com/cloud/ — **no Israel**.

### B2. DigitalOcean
- Basic droplets [V] https://www.digitalocean.com/pricing/droplets : $4.00 (512 MiB/1 vCPU/10 GiB/500 GiB), **$6.00 (1 GiB/1 vCPU/25 GiB/1,000 GiB)**, **$12.00 (2 GiB/1 vCPU/50 GiB/2,000 GiB)**, $18.00 (2 GiB/2 vCPU/60 GiB/3,000 GiB). Note: "Public IPv4 addresses for Droplets with v5 configurations are billed separately … The introductory line-item price is currently $0.00/hour, but is subject to change."
- Reserved IP: "All reserved IPs are free when assigned to a Droplet"; "$5.00 per month ($0.01 per hour) when reserved but not assigned" [V] https://docs.digitalocean.com/products/networking/reserved-ips/details/pricing/ ⇒ guaranteed static via reserved IP at $0 while attached.
- **Total: $12/mo (2 GiB) or $6/mo (1 GiB).** Regions: NYC, SFO, AMS, SGP, LON, FRA, TOR, BLR, SYD, ATL, RIC, MKC, MEM — **no Israel/Middle East** [V] https://docs.digitalocean.com/platform/regional-availability/.

### B3. Vultr (has Tel Aviv)
- Public plans API [V] https://api.vultr.com/v2/plans : vc2-1c-0.5gb $3.50 (512 MB, not in TLV), **vc2-1c-1gb $5/mo (1 vCPU/1 GB/25 GB/1 TB) — available in `tlv`**, **vc2-1c-2gb $10/mo (1 vCPU/2 GB/55 GB/2 TB) — available in `tlv`**; IPv6-only variant vc2-1c-0.5gb-v6 $2.50.
- Region `tlv` = "Tel Aviv, IL", options include `nat_gateway`, `public_ip` [V] https://api.vultr.com/v2/regions. Vultr announced the Tel Aviv location (with Bezeq) in May 2023 [V] https://blogs.vultr.com/vultr-tel-aviv.
- Reserved-IP pricing and whether the instance's main IPv4 is retained across stop/start were not on pages we could fetch (pricing page returned a 5 KB bot-block) [U].
- **Total: $10/mo (2 GB, Tel Aviv).**

### B4. Linode / Akamai
- Public API [V] https://api.linode.com/v4/linode/types : **Nanode 1GB $5.0/mo** (1 GB/1 vCPU/25 GB/1 TB), **Linode 2GB $12.0/mo** (2 GB/1 vCPU/50 GB/2 TB); regional surcharges only for Jakarta/São Paulo. Regions API: 33 regions, **none in Israel** (nearest: nl-ams, de-fra-2, fr-par, it-mil, es-mad, se-sto, gb-lon) [V] https://api.linode.com/v4/regions. Additional-IPv4 price [U] (pricing page is JS-rendered). Included IPv4 persistence: [U].

### B5. AWS Lightsail
- [V] https://aws.amazon.com/lightsail/pricing/ : cheapest Linux "$5/month — 0.5 GB Memory, 2 vCPUs, 20 GB SSD, 1 TB Transfer"; IPv6-only equivalent "$3.50". Regions listed: no Tel Aviv [V]. 1–2 GB plan prices were truncated in our fetch [U].
- Static IP: "There are no costs associated with Static IP addresses when they are attached to a Lightsail instance"; "$0.005 USD/hour fee for static IPs not attached to an instance for more than 1 hour" [V] FAQ URL above; without a static IP "each time you stop or restart your instance, Lightsail assigns a new public IP address" [V] https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-static-ip-addresses-in-amazon-lightsail.html.
- Free trial: replaced by the AWS Free Tier credits [V]. **Fit: 0.5 GB plan too small; no Israel region.**

### B6. Scaleway (France/NL/PL)
- [V] https://www.scaleway.com/en/pricing/virtual-instances/ : "STARDUST1-S 1 vCPU 1 GB 100 Mbps €0.0006 / HOUR ~€0.43 / MONTH", "DEV1-S 2 vCPUs 2 GB 200 Mbps €0.00898 / HOUR ~€6.55 / MONTH", "PLAY2-PICO 1 vCPU 2 GB … ~€10.42 / MONTH". "List prices include egress and IPv6 addresses. Storage (local, block) and attached public IPv4 addresses are excluded."
- IPv4: "Additional IP address … €0.005/hour" ≈ **€3.65/mo** [V] https://www.scaleway.com/en/pricing/network/ (flexible IP = static, reassignable).
- **Total: DEV1-S ≈ €6.55 + €3.65 IPv4 + block storage (price [U]) ≈ €10.2+/mo.** Stardust availability is limited/stock-dependent [U]. No Israel region [U — region list not fetched].

### B7. OVHcloud
- [V] https://www.ovhcloud.com/en/vps/ (USD site): "VPS-1 From $4.54 /month — 2 vCores, 4 GB RAM, 40 GB SSD NVMe", "Dedicated IPv4", "Unlimited traffic"; the "from" price requires a **12-month upfront commitment**; no-commitment monthly price not shown [U]. No Israeli/Middle-East location mentioned [V].

### B8. Contabo
- [V] https://contabo.com/en/vps/ : "Cloud VPS 4 €5.50 / month Including VAT … for the first 24 months — 4 vCPU Cores, 8 GB RAM, 100 GB SSD, 200 Mbit/s Port, Unlimited Traffic*"; "The price displayed is the effective monthly rate for a 24-month subscription including applicable taxes. Minimum initial contract length: 1 month". "Dedicated IPv4 and IPv6 addresses come with every plan." Locations: EU, UK, US, Singapore, Japan, India, Australia — **no Israel**. Shorter-term price and any setup fee: [U] (not in page text).

### B9. netcup
- [V] https://www.netcup.com/en/server/vps : "VPS 500 G12 — 2 vCore (x86), 4 GB DDR5 RAM (ECC), 128 GB NVMe, Traffic included — €0.010 per hour or monthly starting at €5.91 (incl. 19% VAT)"; VPS 1000 G12 (4 vCore/8 GB/256 GB) €10.37. Network options include "IPv4 and IPv6 connectivity". Locations: "Vienna (VIE), Nuremberg (NUE), Amsterdam (AMS), Manassas/USA (MNZ) and Singapore (SIN)" — no Israel. The €5.91 is the 12-month-term price; hourly billing has "no minimum contract terms".

### B10. Kamatera (has Tel Aviv) — see C-section for Israel

---

## Part C — Israel-located options

| Provider / region | Verified? | Cheapest fitting plan | IPv4 | Monthly total (approx) |
|---|---|---|---|---|
| **AWS il-central-1 (Tel Aviv)** | [V] official price list CSV https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/il-central-1/index.csv — "t4g.micro 2 vCPU 1 GiB $0.0097/h" (≈$7.08), "t4g.small 2 vCPU 2 GiB $0.0193/h" (≈$14.09), "t3.micro $0.012/h" (≈$8.76), "t3.small $0.024/h" (≈$17.52) | t4g.small (2 GiB) | "ILC1-PublicIPv4:InUseAddress $0.005/h" (≈$3.65) [V] AmazonVPC il-central-1 price list; Elastic IP = persistent reserved address [U — doc not fetched today] | **≈ $17.74 + EBS gp3 (price [U], ~few $) ≈ $20/mo**; t4g.micro variant ≈ $10.73 + disk |
| **Google Cloud me-west1 (Tel Aviv)** | region exists [V] (network & Cloud Run pricing pages list "Tel Aviv (me-west1)"); e2 prices for me-west1 [U] (JS) | e2-small/medium | static external IP $0.005/h ≈ $3.65 [V] | **[U] total** (VM price unknown) + $3.65 IP |
| **Azure Israel Central** | [V] retail price API (see A4 follow-up) | B2ats_v2 (2 vCPU/1 GiB) $7.81 or B1ms (1 vCPU/2 GiB) $17.52 | Standard static IPv4 $0.005/h ≈ $3.65 [V] | **≈ $14.34/mo (B2ats_v2 + IP + E4 32 GB disk $2.88)**; 2 GiB: ≈ $24.05 |
| **Oracle il-jerusalem-1** | region exists [V] https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm ; Always Free only in the *home region*; whether Jerusalem is offered as home region at sign-up and has A1 capacity [U] | A1 2 OCPU/12 GB (free) | reserved public IP, no price-list charge [V by absence] | **$0** if free tier works there |
| **Vultr tlv** | [V] API | vc2-1c-2gb | included | **$10/mo** (2 GB) / $5 (1 GB) |
| **Kamatera "Israel, Tel Aviv"** | [V] https://www.kamatera.com/pricing/ : "$4 /mo — 1 vCPU (2667 MHz) Type A, 1 GB RAM, 20 GB NVMe SSD, 5 TB Internet Traffic"; "Standard $25/mo 2 vCPU Type B, 2 GB"; "Additional storage … $0.05 per GB per month"; "free 30-day trial … up to $100 on 1 server" | Basic $4 (1 GB — tight) | included (per-IP price [U]) | **$4/mo** (1 GB); custom 2 GB config price [U] |
| **ActiveCloud (Israel DC, also Amsterdam)** | [V] https://activecloud.co.il/... : "AC-Lin50 ₪87/mo — 2 vCPU, 4 GB, 30 GB SSD, 1 IP", prices "לפני מע"מ" (excl. VAT), managed + daily backups | AC-Lin50 | 1 static IP included | **₪87 + VAT ≈ ₪102/mo** |
| **Sweethome (Israel)** | [V] https://www.sweethome.co.il/vps : "VPS Entry ₪89 — 1 vCPU, 2 GB, 50 GB SSD/RAID", VAT included; IP allocation not detailed [U] | VPS Entry | [U] | **₪89/mo incl. VAT** |
| **HostAllow (Israel DC)** | [V] https://hostallow.co.il/vps-israel : "החל מ-₪100 / חודש", "כתובת IP ייעודית" (dedicated IP); specs not on page [U] | — | dedicated IP | **from ₪100/mo** |

Not in Israel (verified): Hetzner, DigitalOcean, Linode, Lightsail, Fly.io, OVH, Contabo, netcup.

---

## Part D — Static egress add-ons for serverless

- **GCP Cloud Run + Cloud NAT + static IP** [V] https://cloud.google.com/nat/pricing : NAT gateway "Up to 32 VM instances: $0.0014 × the number of VM instances that are using the gateway" per hour, "$0.045" per GiB processed, "$0.005" per hour per external IP used by the gateway. Cloud Run instance-based billing [V] https://cloud.google.com/run/pricing : "CPU (per vCPU-second) $0.000018", "Memory (per GiB-second) $0.000002"; free tier "First 240,000 vCPU-seconds" and "First 450,000 GiB-seconds" per month. For an always-on 1 vCPU / 1 GiB instance (2.63 M s/month): CPU ≈ $47.3 + RAM ≈ $5.3 − free tier (≈$5.2) ≈ **$47/mo compute** + NAT (≈$1.0 gateway if counted as 1 instance [U how Cloud Run instances are counted] + $3.65 IP + $0.045/GB ≈ $2–5) ⇒ **≈ $55/mo**. me-west1 is a Cloud Run region [V]. **Verdict: 5–10× a VPS — reject for a 24/7 poller.**
- **AWS Lambda + NAT Gateway** [V] https://aws.amazon.com/vpc/pricing/ : NAT "$0.045 per hour" (≈ **$32.85/mo**) + "$0.045" per GB processed + Elastic IP $0.005/h (≈$3.65) ⇒ **≈ $37/mo before Lambda** (il-central-1 NAT price not captured [U]). Reject.
- **QuotaGuard Static** [V] https://www.quotaguard.com/pricing : Starter "$19/mo — 20,000 requests/month, 10 GB bandwidth"; Production $49 (100k); Business $89 (250k); Enterprise $219 (1,000,000 requests / 1 TB). No free plan ("Free trial on every plan — 3 days"). Our poller (a few hundred requests/min ≈ up to ~10 M/month) exceeds even Enterprise. Reject.
- **Fixie** [V] https://usefixie.com/pricing : "tricycleFree 500 requests $0/month", "commuter 2,500 $5", "cruiser 25,000 $19", "hybrid 250,000 $49", "mountain 1,000,000 $99", "cyclocross 2,000,000 $199", "racing 10,000,000 $499". Our volume ⇒ $199–499/mo. Reject.
- **Fly.io static egress IP** (A5) is effectively the cheapest "add-on" model at $3.60/mo, but it is tied to a Fly Machine, not usable from other platforms.

---

## Part E — Does MOT require an *Israeli* IP or block cloud ranges?

What was found (only public sources; the gov.il SIRI page https://www.gov.il/he/departments/general/real_time_information_siri returned a Cloudflare 403 to automated fetch [U]):

1. **curlbus README** [V] https://raw.githubusercontent.com/elad661/curlbus/master/README.md : "the API access requires your IP to be added to the whitelist, which means you have to have a static IP. Not great for cloud deployments." — states *static*, says nothing about *Israeli*.
2. **Hasadna forum** (SIRI improvement thread) [V] https://forum.hasadna.org.il/t/siri/1094 : "הגישה לSIRI היא רק ע"י כתובת IP שאושרה ע"י משרד התחבורה" ("access to SIRI is only via an IP address approved by the Ministry of Transport"). Nothing about geography or cloud ranges.
3. **hasadna/open-bus-siri-requester** [V] https://raw.githubusercontent.com/hasadna/open-bus-siri-requester/main/README.md : the requester runs through an SSH tunnel (`OPEN_BUS_SSH_TUNNEL_SERVER_IP`, `OPEN_BUS_SSH_TUNNEL_PRIVATE_KEY_FILE`) — i.e. Hasadna's cloud workers reach MOT via a separate host that holds the whitelisted IP. Where that host is (Israel or abroad) is not documented [U].
4. **GitHub issue search** for "moran.mot.gov.il" [V] https://api.github.com/search/issues?q=moran.mot.gov.il : only 2 hits, hasadna/open-bus#367 (2022-01, "Empty reply from server"; shows `moran.mot.gov.il` resolving to `199.203.58.17`, port 110 at that time) and #400 (2022-07, MOT timeouts). Neither discusses IP nationality or cloud blocking.
5. **MOT application form** (already captured in `israel-app-backends.md`, [V] https://www.gov.il/BlobFolder/generalpage/real_time_information_siri/he/real_time_information_receipt_form.pdf — downloaded again today, 1 page, Hebrew text is glyph-encoded so not re-parsed): asks for a *static IP* and suggests "contact your communications provider to obtain a static IP". No stated requirement that the IP be Israeli.
6. Tapuz thread [V] https://www.tapuz.co.il/threads/...14267408/ : only points to the MOT contact e-mail; nothing on IP policy.
7. Hebrew/English web searches ("SIRI משרד התחבורה כתובת IP סטטית", "moran.mot.gov.il IP whitelist cloud") surfaced **no** statement that foreign or cloud IPs are refused.

**Conclusion: no public evidence that MOT requires an Israeli IP or blocks cloud providers; the only documented requirement is a single static IP registered on the form.** Community projects (curlbus, Hasadna) evidently run on ordinary hosting. Because it is unverified either way, the safest plan is: apply with a cheap **Israel-located** static IP if the cost delta is small (Vultr Tel Aviv $10, Kamatera $4), or ask `ptsupport@mot.gov.il` explicitly before committing to a non-Israeli host. [Recommendation, not a verified fact]

---

## Part F — Ranked recommendation

1. **Best free: Oracle Cloud Always Free, Arm A1 (up to 2 OCPU / 12 GB RAM, 200 GB block storage, 10 TB egress) + a *reserved* public IP — $0/month [V].** Home region must be chosen at sign-up and cannot change; pick Frankfurt/Milan/Amsterdam (or Jerusalem if offered — [U]). Caveats [V]: real credit/debit card required (no prepaid/virtual), 7-day idle reclamation if CPU *and* network *and* memory all stay under 20 % (a 15–30 s poller plus an in-memory GTFS/Redis on a 6–12 GB VM should clear the memory or CPU bar, but monitor it), A1 capacity shortages [U], accounts idle 30 days may be terminated, 30-day $300 trial credits are irrelevant to us. Fallback "nearly free": GCP free e2-micro (US only, 1 GB RAM, IP not free) ≈ $3.65/mo — RAM too small for a comfortable GTFS import.
2. **Best cheap: Hetzner Cloud CX23 (2 vCPU / 4 GB / 40 GB NVMe / 20 TB) €5.49 + Primary IPv4 €0.50 = €5.99/mo excl. VAT [V]**, Germany/Finland. IP is a first-class reserved resource (static, re-assignable). Alternatives at similar cost: netcup VPS 500 G12 (2 vCore/4 GB/128 GB) €5.91 incl. VAT on a 12-month term [V]; Contabo Cloud VPS 4 (4 vCPU/8 GB) €5.50 incl. VAT on a 24-month term [V]; DigitalOcean $12 (2 GiB) with free reserved IP [V]; Fly.io ≈ $10.3–15.5 with a $3.60 app-scoped static egress IP [V] if you prefer containers over a VM.
3. **Best Israel-located: Vultr Tel Aviv `vc2-1c-2gb` (1 vCPU / 2 GB / 55 GB / 2 TB) $10/mo [V]** (or `vc2-1c-1gb` $5 if you stream the GTFS import). Cheaper but tighter: Kamatera Tel Aviv $4/mo (1 GB) [V]. Hyperscaler options in Israel cost more: Azure Israel Central B2ats_v2 + static IP + 32 GB disk ≈ $14.34/mo (1 GiB) [V]; AWS il-central-1 t4g.small + public IPv4 ≈ $17.74/mo + EBS [V/U]; Oracle Jerusalem $0 only if the free tier can be homed there [U]. Israeli local hosts (ActiveCloud ₪87 + VAT, Sweethome ₪89, HostAllow from ₪100) are 3–4× the price of Vultr/Kamatera for similar specs [V].

Rejected outright for our use-case (no static egress or ≥$100/mo for it): Render ($100/mo per IP set), Vercel ($100/mo), Railway (Pro $20 + usage, 3 IPs), Koyeb (none), Cloudflare Workers (none), Deno Deploy (none), Heroku (Private Spaces only), Cloud Run+NAT (~$55/mo), Lambda+NAT (~$37/mo before compute), QuotaGuard/Fixie (request-metered, $99–$499 at our volume). Northflank has a real dedicated egress IP but unpublished pricing [U].

## Part G — Comparison table

| Provider / plan | Monthly cost (our workload) | Static egress IP — how / cost | RAM / disk | Regions (Israel?) | Free-tier gotchas | Verified |
|---|---|---|---|---|---|---|
| Oracle Always Free A1.Flex | **$0** | Reserved public IP (persistent, re-assignable); no price-list charge | up to 12 GB / 200 GB | Home region only; il-jerusalem-1 exists (home-region eligibility [U]) | card required (no prepaid), 7-day idle reclamation (CPU&net&mem <20 %), A1 capacity, home region locked | [V] (capacity/Jerusalem [U]) |
| Oracle Always Free E2.1.Micro ×2 | $0 | same | 1 GB / shared 200 GB | same | 1/8 OCPU, 50 Mbps; idle reclamation | [V] |
| GCP free e2-micro | ≈ $3.65 (IP) + egress >1 GB | Reserved static external IP $0.005/h (free tier = 1 h/month only) | 1 GB / 30 GB | us-west1/us-central1/us-east1 only | card required; 1 GB NA egress; 25 % CPU | [V] |
| AWS Free plan (2025+) | $0 for ≤6 months then account closes | Public IPv4 $0.005/h (≈$3.65) | — | il-central-1 exists (paid) | auto-closes at 6 months / credit exhaustion | [V] |
| AWS il-central-1 t4g.small (paid) | ≈ $17.74 + EBS | Elastic IP ≈ $3.65 [IP price V; EIP persistence U] | 2 GiB / EBS | Tel Aviv | — | [V] |
| Azure free → Israel Central | 12 mo: ≈ $3.65 (IP) + disk; after: ≈ $14.34 (B2ats_v2) | Standard static IPv4 $0.005/h | 1 GiB (B1s/B2ats_v2) / E4 32 GB $2.88 | Israel Central | card required; 750 h/mo for 12 months; IP not in free list [U] | [V] |
| Fly.io shared-cpu-1x 1 GB | ≈ $10.27 (2 GB: ≈ $15.46) | App-scoped static egress IPv4 $3.60/mo, persists across deploys | 1–2 GB / $0.15/GB | fra/ams/cdg/lhr — no Israel | no free tier | [V] |
| Render | Pro plan [U] + $100/mo | Dedicated IP set (3 IPv4) $100/mo, Pro+ | — | — | free services sleep after 15 min | [V] |
| Railway Pro | ≈ $30 | Static outbound IPs (3 per service) on Pro ($20/mo incl. $20 usage) | usage-priced $10/GB-mo | — | Hobby has no static IPs | [V] |
| Koyeb | — | none (shared pool, changes without notice) | free 512 MB | fra/was | — | [V] |
| Northflank | free sandbox / $5.40 (512 MB) / $24 (2 GB) + egress IP [U] | Dedicated egress IP (price unpublished) | 256 MB–2 GB / $0.15/GB | europe-west etc. | free services tiny | [V] except price [U] |
| Cloudflare Workers | — | none for Workers | — | — | — | [V] |
| Deno Deploy | — | none mentioned | — | — | — | [V] |
| Vercel Static IPs | $100/mo + $0.15/GB | shared static pair via NAT (Pro); dedicated = Enterprise | functions | — | — | [V] |
| Heroku | Basic $7 dyno; Private Space [U] | only Private Spaces (4 stable IPs) | 0.5 GB | — | no free tier | [V] |
| **Hetzner CX23** | **€5.99 excl. VAT** | Primary IPv4 €0.50/mo (persistent resource) | 4 GB / 40 GB | DE/FI/US/SG — no Israel | plans showed "unavailable" at fetch time [U] | [V] |
| Hetzner CAX11 (Arm) | €6.49 excl. VAT | same | 4 GB / 40 GB | DE/FI | — | [V] |
| DigitalOcean Basic 2 GiB | $12 (1 GiB: $6) | Reserved IP free while assigned ($5/mo unassigned) | 2 GiB / 50 GiB | no Israel | IPv4 "introductory $0.00/h, subject to change" | [V] |
| **Vultr vc2-1c-2gb (tlv)** | **$10** (1 GB: $5) | instance IPv4 included; reserved-IP price [U] | 2 GB / 55 GB | **Tel Aviv** | free plan exists but 512 MB, not TLV, eligibility [U] | [V] |
| Linode Nanode / 2GB | $5 / $12 | included IPv4; extra-IP price [U] | 1–2 GB / 25–50 GB | no Israel | — | [V] |
| AWS Lightsail $5 | $5 (0.5 GB) | static IP free while attached | 0.5 GB / 20 GB | no Tel Aviv | free trial replaced by credits | [V] |
| Scaleway DEV1-S | ≈ €6.55 + €3.65 IPv4 + storage | flexible IPv4 €0.005/h | 2 GB / (block storage extra) | FR/NL/PL [U] | Stardust (€0.43) stock-limited [U] | [V] |
| OVH VPS-1 | $4.54 (12-month prepaid) | dedicated IPv4 included | 4 GB / 40 GB | no Israel | monthly price [U] | [V] |
| Contabo Cloud VPS 4 | €5.50 incl. VAT (24-month) | dedicated IPv4 included | 8 GB / 100 GB | no Israel | term/setup for 1-month [U] | [V] |
| netcup VPS 500 G12 | €5.91 incl. VAT (12-month) or €0.010/h | IPv4 included option | 4 GB / 128 GB | AT/DE/NL/US/SG | — | [V] |
| **Kamatera Basic (Tel Aviv)** | **$4** | included | 1 GB / 20 GB | **Tel Aviv** | 30-day $100 trial | [V] |
| ActiveCloud AC-Lin50 | ₪87 + VAT | 1 static IP | 4 GB / 30 GB | Israel | managed, backups | [V] |
| Sweethome VPS Entry | ₪89 incl. VAT | [U] | 2 GB / 50 GB | Israel | — | [V] |
| HostAllow | from ₪100 | dedicated IP | [U] | Israel | — | [V] partial |
| GCP Cloud Run + Cloud NAT | ≈ $55 | NAT static IP $0.005/h + $0.0014/h/instance + $0.045/GB | 1 GiB | me-west1 available | free tier small | [V] |
| AWS Lambda + NAT GW | ≈ $37 + Lambda | NAT $0.045/h + $0.045/GB + EIP | — | il-central-1 | — | [V] |
| QuotaGuard Static | $19–$219 (insufficient) | proxy | — | — | no free plan (Heroku add-on: 250 req free) | [V] |
| Fixie | $0 (500 req) … $499 (10 M) | proxy | — | — | free tier useless at our volume | [V] |

**Could not verify today ([U] summary):** Oracle A1 availability/home-region eligibility for Jerusalem; GCP e2 prices in me-west1; Azure free-account treatment of public IPs; Hetzner plan availability (page showed "unavailable"); Northflank egress-IP price; Vultr/Linode reserved-IP prices; Lightsail 1–2 GB plan prices; OVH/Contabo month-to-month prices; Scaleway block-storage price and regions; the gov.il SIRI page text (Cloudflare 403) and hence any official statement on IP nationality; Heroku Private Spaces price.

---

## Second-pass verification (2026-09-17, checked directly in a browser or against official docs)

| Claim in this report | Result of re-check |
|---|---|
| Hetzner CX23 €5.49 + IPv4 €0.50 | ❌ **Not orderable today.** hetzner.com/cloud/cost-optimized lists CX23, CAX11 and every other Cost-Optimized plan as "This product is currently unavailable. Please check back later." with no price shown. The cheapest **available** plan on /cloud/regular-performance is **CPX12: €11.99/month (€0.0192/h), 1 AMD vCPU, 2 GB RAM, 40 GB NVMe** (shown with EUR, VAT 0%; the page says "Price incl. IPv4") |
| Oracle Always Free A1 = 2 OCPU / 12 GB, 200 GB block, 10 TB egress, compute only in home region, 7-day idle reclamation | ✅ Confirmed verbatim on docs.oracle.com (freetier_topic-Always_Free_Resources.htm). Idle = over 7 days, 95th-percentile CPU < 20% **and** network < 20% **and** memory < 20% (A1). Our poller is light on CPU and network, so **memory must stay ≥ 20% (≈2.4 GB of 12 GB) or the VM can be reclaimed**. "Out of host capacity" errors are documented |
| Oracle reserved public IP is persistent | ✅ docs (managingpublicIPs.htm): "persistent and exists beyond the lifetime of the instance… exists until you delete it"; 50 per region. That it costs $0 is only inferred from its **absence** on the price list; no page states "free" |
| Vultr Tel Aviv $10/month | ⚠️ Tel Aviv-Yafo is listed on vultr.com/features/datacenter-locations ✅, but the pricing page says prices **vary by location and are only shown in the Control Panel**, so the Tel Aviv price is unverifiable without an account |
| Kamatera Tel Aviv $4/month | ❓ Not re-checked (the browser tool isn't permitted on kamatera.com) |
