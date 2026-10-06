#[cfg(test)]
mod http3_independent_control_credit_algebra {
    use super::*;
    use crate as quiche;
    use std::time::{Duration, Instant};
    include!("http3_flow_credit_transport_settings.rs");

    #[test]
    fn provider_envelope_covers_all_advertised_stream_windows() {
        let mut config = Config::new(PROTOCOL_VERSION).unwrap();
        apply_provider_quic_transport_settings(&mut config);
        let tp = &config.local_transport_params;
        assert_eq!(tp.initial_max_streams_bidi, 100);
        assert_eq!(tp.initial_max_streams_uni, 3);
        for initial in [
            tp.initial_max_stream_data_bidi_local,
            tp.initial_max_stream_data_bidi_remote,
            tp.initial_max_stream_data_uni,
        ] {
            assert_eq!(initial, 1_000_000);
            assert!(initial <= config.max_stream_window);
        }
        let request_exposure = tp.initial_max_streams_bidi * config.max_stream_window;
        let uni_exposure = tp.initial_max_streams_uni * config.max_stream_window;
        let exposure = request_exposure + uni_exposure;
        assert_eq!(config.max_stream_window, 16 * 1024 * 1024);
        assert_eq!(tp.initial_max_data, 2 * exposure);
        assert_eq!(config.max_connection_window, 2 * exposure);
        assert_eq!(tp.initial_max_data, 3_456_106_496);

        for held_request in [0, 1_000_000, request_exposure] {
            for held_uni in [0, 9, uni_exposure] {
                assert!(exposure - held_request - held_uni >= uni_exposure - held_uni);
            }
        }
    }

    #[test]
    fn prior_consumption_strict_half_and_autotune_keep_envelope() {
        let mut config = Config::new(PROTOCOL_VERSION).unwrap();
        apply_provider_quic_transport_settings(&mut config);
        let c = config.local_transport_params.initial_max_data;
        let r = c / 2;
        let mut fc = flowcontrol::FlowControl::new(c, c, config.max_connection_window);
        let now = Instant::now();
        fc.add_consumed(r + 7);
        assert!(fc.should_update_max_data());
        fc.update_max_data(now);
        let committed_consumed = fc.consumed();
        assert_eq!(fc.max_data(), committed_consumed + c);
        fc.add_consumed(r - 1);
        assert!(!fc.should_update_max_data());
        fc.add_consumed(1);
        assert!(!fc.should_update_max_data());
        assert_eq!(fc.max_data() - fc.consumed(), r);
        fc.add_consumed(1);
        assert!(fc.should_update_max_data());
        fc.autotune_window(now, Duration::from_millis(10));
        fc.ensure_window_lower_bound(config.max_stream_window * 3 / 2);
        assert_eq!(fc.window(), c);
        fc.update_max_data(now);
        assert_eq!(fc.max_data(), fc.consumed() + c);
    }
}
