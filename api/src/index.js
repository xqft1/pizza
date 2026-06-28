const TOKEN_ADDRESS = "0x831A3962e31037cf4Eb8847cb7eA05aaC1Db35B6";
const DECIMALS = 18n;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname !== "/api/supply" && url.pathname !== "/supply") {
      return Response.json(
        {
          error: "Not found",
          available_endpoints: ["/api/supply", "/supply"]
        },
        { status: 404 }
      );
    }

    if (!env.ETH_RPC_URL) {
      return Response.json(
        { error: "Missing ETH_RPC_URL secret" },
        { status: 500 }
      );
    }

    const rpcBody = {
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [
        {
          to: TOKEN_ADDRESS,
          data: "0x18160ddd" // totalSupply()
        },
        "latest"
      ]
    };

    const rpcResponse = await fetch(env.ETH_RPC_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(rpcBody)
    });

    const rpcJson = await rpcResponse.json();

    if (!rpcJson.result) {
      return Response.json(
        {
          error: "Could not fetch token supply",
          details: rpcJson
        },
        { status: 500 }
      );
    }

    const rawSupply = BigInt(rpcJson.result);
    const divisor = 10n ** DECIMALS;
    const wholeSupply = rawSupply / divisor;

    return Response.json({
      name: "Pizza",
      symbol: "PIZZA",
      contract: TOKEN_ADDRESS,
      chain: "ethereum",
      decimals: Number(DECIMALS),
      circulating_supply: wholeSupply.toString(),
      total_supply: wholeSupply.toString(),
      raw_supply: rawSupply.toString(),
      updated_at: new Date().toISOString()
    });
  }
};
