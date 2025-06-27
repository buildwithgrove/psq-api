import { NextApiRequest, NextApiResponse } from 'next';
import { addQueryRequest } from './query/[secret]';

interface RequestBody {
  pokt_node_domain: string;
  date: string;
  'payor-address': string;
}

function generateSecret(): string {
  return Math.floor(10000000 + Math.random() * 90000000).toString();
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const body: RequestBody = req.body;
    
    if (!body.pokt_node_domain || !body.date || !body['payor-address']) {
      return res.status(400).json({ error: 'Missing required fields: pokt_node_domain, date, payor-address' });
    }

    // Validate date format (YYYY-MM-DD)
    const dateRegex = /^\d{4}-\d{2}-\d{2}$/;
    if (!dateRegex.test(body.date)) {
      return res.status(400).json({ error: 'Invalid date format. Use YYYY-MM-DD' });
    }

    const secret = generateSecret();
    const timestamp = Date.now();
    
    // Add query request for async processing
    addQueryRequest({
      secret,
      domain: body.pokt_node_domain,
      date: body.date,
      payorAddress: body['payor-address'],
      timestamp,
      status: 'pending'
    });

    // Return secret immediately
    res.status(200).json({ 
      secret,
      message: 'Payment required. Send 20000000upokt to pokt1lf0kekv9zcv9v3wy4v6jx2wh7v4665s8e0sl9s with memo containing this secret.',
      status_url: `/api/query/${secret}`
    });

  } catch (error) {
    console.error('API Error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}