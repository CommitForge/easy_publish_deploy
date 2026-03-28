curl -X POST http://localhost:8081/izipublish/update-chain/sync \
	  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "containerChainId=0xc225e0fc9f648d95e90e8b0bbb0aecf4122c90f7c8e9f137b64603685a796266" \
  -d "updateChainId=0x6c5215f9827413e25fad5f746e01c50e523caf704d65d4c7db35ddd38a8de30b" \
  -d "dataItemChainId=0x21e241879bc5dad7046d742e06f60ccd8e2b66b5609a48d8d25714e4253166f2" \
  -d "dataItemVerificationChainId=0x1cfbe6f207b6f3851ac37d879a47f6a3262514d4b809c5f15cc971c62e2929b9"
