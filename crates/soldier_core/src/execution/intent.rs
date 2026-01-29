use crate::risk::TradingMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntentAction {
    Place,
    Cancel,
    Close,
    Hedge,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntentClass {
    Open,
    Close,
    Cancel,
}

impl IntentClass {
    pub fn from_action(action: IntentAction, reduce_only: Option<bool>) -> Self {
        match action {
            IntentAction::Cancel => IntentClass::Cancel,
            IntentAction::Close | IntentAction::Hedge => IntentClass::Close,
            IntentAction::Place => {
                if reduce_only == Some(true) {
                    IntentClass::Close
                } else {
                    IntentClass::Open
                }
            }
            IntentAction::Unknown => IntentClass::from_reduce_only(reduce_only),
        }
    }

    pub fn from_reduce_only(reduce_only: Option<bool>) -> Self {
        if reduce_only == Some(true) {
            IntentClass::Close
        } else {
            IntentClass::Open
        }
    }

    pub fn is_open(self) -> bool {
        matches!(self, IntentClass::Open)
    }

    pub fn allowed_in_mode(self, mode: TradingMode) -> bool {
        match self {
            IntentClass::Open => mode.allows_open(),
            IntentClass::Close => mode.allows_close(),
            IntentClass::Cancel => mode.allows_cancel(),
        }
    }
}
