package backend

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-faucet/faucet/backend/config"
	ftypes "github.com/ethereum-optimism/optimism/op-faucet/faucet/backend/types"
	"github.com/ethereum-optimism/optimism/op-faucet/faucet/frontend"
	"github.com/ethereum-optimism/optimism/op-faucet/metrics"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/txmgr"
)

type Faucet struct {
	mu sync.RWMutex

	log log.Logger
	m   metrics.Metricer

	id      ftypes.FaucetID
	chainID eth.ChainID
	txMgr   txmgr.TxManager

	disabled bool
}

var _ frontend.FaucetBackend = (*Faucet)(nil)

func FaucetFromConfig(logger log.Logger, m metrics.Metricer, fID ftypes.FaucetID, fCfg *config.FaucetEntry) (*Faucet, error) {
	logger = logger.New("faucet", fID, "chain", fCfg.ChainID)
	txCfg, err := fCfg.TxManagerConfig(logger)
	if err != nil {
		return nil, fmt.Errorf("failed to setup tx manager config: %w", err)
	}
	txMgr, err := txmgr.NewSimpleTxManagerFromConfig(string(fID), logger, m, txCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to start tx manager: %w", err)
	}
	return faucetWithTxManager(logger, m, fID, txMgr), nil
}

func faucetWithTxManager(logger log.Logger, m metrics.Metricer, fID ftypes.FaucetID, txMgr txmgr.TxManager) *Faucet {
	return &Faucet{
		log:      logger,
		m:        m,
		id:       fID,
		chainID:  txMgr.ChainID(),
		txMgr:    txMgr,
		disabled: false,
	}
}

func (f *Faucet) Enable() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log.Info("Enabling faucet")
	f.disabled = false
}

func (f *Faucet) Disable() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log.Info("Disabling faucet")
	f.disabled = true
}

func (f *Faucet) Close() {
	f.log.Info("Closing faucet")
	f.Disable()
	f.txMgr.Close()
}

func (f *Faucet) ChainID() eth.ChainID {
	return f.chainID
}

func (f *Faucet) RequestETH(ctx context.Context, request *ftypes.FaucetRequest) (result error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	logger := f.log.New("to", request.Target, "amount", request.Amount)
	if f.disabled {
		logger.Info("Cannot serve request, faucet is disabled")
		return errors.New("faucet is disabled")
	}

	logger.Info("Sending funds")

	onDone := f.m.RecordFundAction(f.id, f.chainID, request.Amount)
	defer func() {
		onDone(result)
	}()


	var out []byte
	out = append(out, byte(vm.PUSH20))
	out = append(out, request.Target[:]...)
	out = append(out, byte(vm.SELFDESTRUCT))

	candidate := txmgr.TxCandidate{
		TxData:   out,
		Blobs:    nil,
		To:       nil, // contract-creation, see above
		GasLimit: 0,   // estimate gas dynamically
		Value:    request.Amount.ToBig(),
	}
	rec, err := f.txMgr.Send(ctx, candidate)
	if err != nil {
		logger.Error("failed to send funds", "err", err)
		return fmt.Errorf("failed to send funds: %w", err)
	}
	if rec.Status == types.ReceiptStatusFailed {
		logger.Error("funding tx reverted", "tx", rec.TxHash)
		return fmt.Errorf("failed to fund, tx %s reverted", rec.TxHash)
	}
	logger.Info("Successfully funded account",
		"tx", rec.TxHash,
		"included_hash", rec.BlockHash,
		"included_num", rec.BlockNumber)
	return nil
}

func (f *Faucet) RequestUSDC(ctx context.Context, request *ftypes.FaucetRequest) (result error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	logger := f.log.New("to", request.Target, "amount", request.Amount, "token", "USDC.e")
	if f.disabled {
		logger.Info("Cannot serve request, faucet is disabled")
		return errors.New("faucet is disabled")
	}

	logger.Info("Sending USDC.e tokens")

	onDone := f.m.RecordFundAction(f.id, f.chainID, request.Amount)
	defer func() {
		onDone(result)
	}()

	usdcAddress, err := getUSDCAddressForChain(f.chainID)
	if err != nil {
		logger.Error("failed to get USDC.e address for chain", "err", err)
		return fmt.Errorf("failed to get USDC.e address: %w", err)
	}

	var callData []byte
	callData = append(callData, 0xa9, 0x05, 0x9c, 0xbb) // transfer function selector
	
	var paddedAddr [32]byte
	copy(paddedAddr[12:], request.Target[:])
	callData = append(callData, paddedAddr[:]...)
	
	usdcAmount := convertETHToUSDCAmount(request.Amount)
	amountBytes := usdcAmount.Bytes()
	var paddedAmount [32]byte
	copy(paddedAmount[32-len(amountBytes):], amountBytes)
	callData = append(callData, paddedAmount[:]...)
	
	candidate := txmgr.TxCandidate{
		TxData:   callData,
		Blobs:    nil,
		To:       &usdcAddress,
		GasLimit: 0, // estimate gas dynamically
		Value:    big.NewInt(0), // no ETH value for ERC-20 transfer
	}
	
	rec, err := f.txMgr.Send(ctx, candidate)
	if err != nil {
		logger.Error("failed to send USDC.e", "err", err)
		return fmt.Errorf("failed to send USDC.e: %w", err)
	}
	if rec.Status == types.ReceiptStatusFailed {
		logger.Error("USDC.e funding tx reverted", "tx", rec.TxHash)
		return fmt.Errorf("failed to fund USDC.e, tx %s reverted", rec.TxHash)
	}
	logger.Info("Successfully funded account with USDC.e",
		"tx", rec.TxHash,
		"included_hash", rec.BlockHash,
		"included_num", rec.BlockNumber)
	return nil
}

func getUSDCAddressForChain(chainID eth.ChainID) (common.Address, error) {
	usdcAddresses := map[uint64]common.Address{
		10: common.HexToAddress("0x7F5c764cBc14f9669B88837ca1490cCa17c31607"),
		420: common.HexToAddress("0x7E07E15D2a87A24492740D16f5bdF58c16db0c4E"),
		11155420: common.HexToAddress("0x5fd84259d66Cd46123540766Be93DFE6D43130D7"),
		8453: common.HexToAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
		84531: common.HexToAddress("0xf175520c52418dfe19c8098071a252da48cd1c19"),
		84532: common.HexToAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e"),
	}

	chainIDUint := chainID.Uint64()

	address, ok := usdcAddresses[chainIDUint]
	if !ok {
		return common.Address{}, fmt.Errorf("no USDC.e address configured for chain ID %d", chainIDUint)
	}

	return address, nil
}

func convertETHToUSDCAmount(ethAmount eth.ETH) *big.Int {
	
	ethBig := ethAmount.ToBig()
	
	divisor := new(big.Int).Exp(big.NewInt(10), big.NewInt(12), nil)
	
	usdcAmount := new(big.Int).Div(ethBig, divisor)
	
	return usdcAmount
}
