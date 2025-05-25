package types

import (
	"errors"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/rpc"
)

const maxIDLength = 100

var ErrInvalidID = errors.New("invalid ID")

type FaucetID string

func (id FaucetID) String() string {
	return string(id)
}

func (id FaucetID) MarshalText() ([]byte, error) {
	if len(id) > maxIDLength {
		return nil, ErrInvalidID
	}
	if len(id) == 0 {
		return nil, ErrInvalidID
	}
	return []byte(id), nil
}

func (id *FaucetID) UnmarshalText(data []byte) error {
	if len(data) > maxIDLength {
		return ErrInvalidID
	}
	if len(data) == 0 {
		return ErrInvalidID
	}
	*id = FaucetID(data)
	return nil
}

type FaucetRequest struct {
	RpcUser *rpc.PeerInfo
	Target  common.Address
	Amount  eth.ETH
	TokenType string
}
