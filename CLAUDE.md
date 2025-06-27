# Portal Supplier Quality API (psq-api)

## Overview
API that integrates with Grove's BigQuery and pocketd to provide portal supplier quality metrics with payment verification.

## Architecture
- **Deployment**: Vercel
- **Database**: Google BigQuery via gcloud bq interface
- **Payment Verification**: pocketd transaction scanning
- **Output Format**: CSV

## API Specification

### Endpoint
`POST psq-api.grove.city`

### Request Format
```json
{
  "pokt_node_domain": "<DOMAIN>",
  "date": "<YYYY-MM-DD>", 
  "payor-address": "<POKT_ADDRESS>"
}
```

### Response Flow
1. **Immediate Response**: Returns 8-digit secret
2. **Payment Verification**: Scans pocketd for transaction from payor-address to `pokt1lf0kekv9zcv9v3wy4v6jx2wh7v4665s8e0sl9s`
   - Must contain the 8-digit secret in memo field
   - Amount must be ≥ 20000000upokt
   - Timestamp must be after API call
   - Timeout: 5 blocks or 2.5 minutes
3. **Query Execution**: If payment verified, runs BigQuery and returns CSV
4. **Error Response**: HTTP 400 if payment not found within timeframe

## BigQuery Query
```sql
SELECT 
  r.pokt_node_domain as domain, 
  r.date as day, 
  r.chain_id,  
  count(*) as relays, 
  count(CASE WHEN is_error=TRUE and error_type is not null and error_type <> "user" THEN error_type END) as err_cnt,
  1 - (count(CASE WHEN is_error=TRUE and error_type is not null and error_type <> "user" THEN error_type END) / count(*)) as success_rate, 
  avg(relay_roundtrip_time) as avg_total_latency, 
  APPROX_QUANTILES(relay_roundtrip_time, 100)[OFFSET(95)] as p95_latency,
  APPROX_QUANTILES(relay_roundtrip_time, 100)[OFFSET(99)] as p99_latency
FROM `portal-prd-gke-all.RELAYS.D2` r
WHERE r.date = "<DATE>"
AND r.pokt_node_domain = "<DOMAIN>"
GROUP BY r.pokt_node_domain, r.date, r.chain_id
ORDER BY r.date, r.chain_id;
```

## Payment Details
- **Recipient Address**: `pokt1lf0kekv9zcv9v3wy4v6jx2wh7v4665s8e0sl9s`
- **Minimum Amount**: 20000000upokt (20 POKT)
- **Verification Window**: 5 blocks or 2.5 minutes
- **Required Memo**: 8-digit secret from API response

## Environment Configuration

### CHAIN_ENV
Controls which Pocket network to connect to:

- **BETA**: Uses Shannon testnet
  - Node: `https://shannon-testnet-grove-rpc.beta.poktroll.com`
  - Chain ID: `pocket-beta`
- **MAIN** (default): Uses Shannon mainnet  
  - Node: `https://shannon-grove-rpc.mainnet.poktroll.com`
  - Chain ID: `pocket`

### Vercel Environment Variables
Required environment variables in Vercel:
- `GOOGLE_APPLICATION_CREDENTIALS`: Google Cloud service account credentials
- `CHAIN_ENV`: Set to `BETA` or `MAIN`

## Development Commands
- Build: `npm run build`
- Dev: `npm run dev`  
- Deploy: `vercel --prod`

## Local Development
Set environment variables:
```bash
export CHAIN_ENV=BETA
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/credentials.json
npm run dev
```