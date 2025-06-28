import { NextApiRequest, NextApiResponse } from 'next';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

interface QueryRequest {
  secret: string;
  domain: string;
  date: string;
  payorAddress: string;
  timestamp: number;
  status: 'pending' | 'verified' | 'failed' | 'completed';
  result?: string;
  error?: string;
}

// In-memory store (in production, use Redis or database)
const queryRequests = new Map<string, QueryRequest>();

function getPocketdConfig() {
  const chainEnv = process.env.CHAIN_ENV || 'MAIN';
  
  if (chainEnv === 'BETA') {
    return {
      node: 'https://shannon-testnet-grove-rpc.beta.poktroll.com',
      chainId: 'pocket-beta'
    };
  } else {
    return {
      node: 'https://shannon-grove-rpc.mainnet.poktroll.com',
      chainId: 'pocket'
    };
  }
}

async function scanPocketdForPayment(payorAddress: string, secret: string, timestamp: number): Promise<boolean> {
  const targetAddress = 'pokt1lf0kekv9zcv9v3wy4v6jx2wh7v4665s8e0sl9s';
  const minAmount = 20000000;
  const timeoutMs = 150000;
  const startTime = Date.now();
  const config = getPocketdConfig();
  
  while (Date.now() - startTime < timeoutMs) {
    try {
      // Query pocketd for transactions to the target address
      const cmd = `pocketd query bank all-balances ${targetAddress} --node=${config.node} --chain-id=${config.chainId} --output=json`;
      const { stdout } = await execAsync(cmd);
      
      // TODO: Implement actual transaction scanning logic
      // This would need to:
      // 1. Query for transactions to targetAddress
      // 2. Filter by sender (payorAddress)
      // 3. Check timestamp > API call time
      // 4. Verify memo contains the secret
      // 5. Verify amount >= 20000000upokt
      
      console.log(`Querying pocketd for transactions to ${targetAddress}...`);
      console.log(`Balance query result: ${stdout}`);
      
      // For demo purposes, simulate finding payment after 10 seconds
      if (Date.now() - startTime > 10000) {
        console.log(`Payment simulation: Found payment from ${payorAddress} with secret ${secret}`);
        return true;
      }
      
      await new Promise(resolve => setTimeout(resolve, 5000));
    } catch (error) {
      console.error('Error querying pocketd:', error);
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }
  
  return false;
}

async function executeBigQueryQuery(domain: string, date: string): Promise<string> {
  const query = `
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
    FROM \`portal-prd-gke-all.RELAYS.D2\` r
    WHERE r.date = "${date}"
    AND r.pokt_node_domain = "${domain}"
    GROUP BY r.pokt_node_domain, r.date, r.chain_id
    ORDER BY r.date, r.chain_id;
  `;

  try {
    const { stdout } = await execAsync(`bq query --use_legacy_sql=false --format=csv '${query}'`);
    return stdout;
  } catch (error) {
    throw new Error(`BigQuery execution failed: ${error}`);
  }
}

export function addQueryRequest(request: QueryRequest) {
  queryRequests.set(request.secret, request);
  
  // Start async processing
  setTimeout(async () => {
    const req = queryRequests.get(request.secret);
    if (!req) return;

    try {
      const paymentVerified = await scanPocketdForPayment(
        req.payorAddress,
        req.secret,
        req.timestamp
      );

      if (paymentVerified) {
        req.status = 'verified';
        queryRequests.set(req.secret, req);
        
        const csvResult = await executeBigQueryQuery(req.domain, req.date);
        req.status = 'completed';
        req.result = csvResult;
        queryRequests.set(req.secret, req);
      } else {
        req.status = 'failed';
        req.error = 'Payment not found within required timeframe';
        queryRequests.set(req.secret, req);
      }
    } catch (error) {
      req.status = 'failed';
      req.error = `Processing error: ${error}`;
      queryRequests.set(req.secret, req);
    }
  }, 0);
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { secret } = req.query;
  
  if (!secret || typeof secret !== 'string') {
    return res.status(400).json({ error: 'Invalid secret' });
  }

  const queryRequest = queryRequests.get(secret);
  
  if (!queryRequest) {
    return res.status(404).json({ error: 'Query not found' });
  }

  switch (queryRequest.status) {
    case 'pending':
      return res.status(202).json({ status: 'pending', message: 'Waiting for payment verification' });
    
    case 'verified':
      return res.status(202).json({ status: 'verified', message: 'Payment verified, executing query' });
    
    case 'completed':
      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="psq-${queryRequest.domain}-${queryRequest.date}.csv"`);
      return res.status(200).send(queryRequest.result);
    
    case 'failed':
      return res.status(400).json({ error: queryRequest.error || 'Query failed' });
    
    default:
      return res.status(500).json({ error: 'Unknown status' });
  }
}