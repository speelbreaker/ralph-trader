use soldier_core::venue::{FeatureFlags, InstrumentKind, VenueCapabilities};

#[test]
fn test_oco_not_supported() {
    let capabilities = VenueCapabilities::default();
    let flags = FeatureFlags::default();
    let kinds = [
        InstrumentKind::Option,
        InstrumentKind::LinearFuture,
        InstrumentKind::InverseFuture,
        InstrumentKind::Perpetual,
    ];

    for kind in kinds {
        assert!(
            !capabilities.linked_orders_supported_for(kind, flags),
            "linked orders should be disabled by default for {:?}",
            kind
        );
    }
}

#[test]
fn test_oco_supported_when_flags_enabled() {
    let capabilities = VenueCapabilities {
        linked_orders_supported: true,
    };
    let flags = FeatureFlags {
        enable_linked_orders_for_bot: true,
    };

    for kind in [
        InstrumentKind::LinearFuture,
        InstrumentKind::InverseFuture,
        InstrumentKind::Perpetual,
    ] {
        assert!(
            capabilities.linked_orders_supported_for(kind, flags),
            "linked orders should be enabled for {:?} when flags allow",
            kind
        );
    }

    assert!(
        !capabilities.linked_orders_supported_for(InstrumentKind::Option, flags),
        "options never support linked orders",
    );
}
