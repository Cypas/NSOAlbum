use crate::error::{CoreError, CoreResult};
use serde_json::Value;

pub(crate) fn ensure_coral_success(value: &Value) -> CoreResult<()> {
    ensure_coral_success_for_endpoint(value, None)
}

pub(crate) fn ensure_coral_success_for_endpoint(
    value: &Value,
    endpoint: Option<&str>,
) -> CoreResult<()> {
    let status = value
        .get("status")
        .and_then(Value::as_i64)
        .ok_or_else(|| CoreError::Provider("nintendo_response_invalid".into()))?;
    let code = match status {
        0 if !value.get("errorMessage").is_some_and(Value::is_string) => return Ok(()),
        429 | 9437 => {
            return Err(CoreError::RateLimited {
                retry_after_seconds: 60,
            });
        }
        9403 | 9404 | 9599 => {
            return Err(CoreError::Authentication(format!(
                "Nintendo account session rejected (status {status})"
            )));
        }
        9400 => "nintendo_request_invalid",
        9408 if endpoint == Some("/v3/Friend/GetUserByFriendCode") => {
            "nintendo_friend_code_not_found"
        }
        9405 | 9406 => "nintendo_request_forbidden",
        9407 => "nintendo_account_not_linked",
        9423 => "nintendo_age_restricted",
        9424 => "nintendo_user_not_activated",
        9427 => "nintendo_client_update_required",
        9428 => "nintendo_account_disabled",
        9450 => "nso_membership_required",
        9461 => "nintendo_sender_friend_limit",
        9462 => "nintendo_receiver_friend_limit",
        9464 => "nintendo_friend_request_pending",
        9467 => "nintendo_already_friend",
        9468 => "nintendo_friend_request_blocked",
        9499 => "nintendo_service_closed",
        9500 | 9501 => "nintendo_service_unavailable",
        9511 => "nintendo_service_maintenance",
        _ => "nintendo_request_failed",
    };
    Err(CoreError::Provider(format!("{code} (status {status})")))
}

/// These HTTP mappings apply only to SplatNet's bullet-token endpoint.
pub(crate) fn bullet_status_error(status: u16) -> Option<CoreError> {
    let code = match status {
        204 => "splatnet_user_not_registered",
        400 => "splatnet_request_invalid",
        401 => {
            return Some(CoreError::Authentication(
                "splatnet_game_web_token_invalid (HTTP 401)".into(),
            ));
        }
        403 => "splatnet_version_outdated",
        499 => "splatnet_access_restricted",
        500 | 599 => "splatnet_service_unavailable",
        503 => "splatnet_service_maintenance",
        _ => return None,
    };
    Some(CoreError::Provider(format!("{code} (HTTP {status})")))
}

pub(crate) fn safe_activity_condition(error: &CoreError) -> Option<&'static str> {
    if matches!(error, CoreError::Authentication(code) if code == "nintendo_sign_in_required") {
        return Some("nintendo_sign_in_required");
    }
    let CoreError::Provider(message) = error else {
        return None;
    };
    let code = message.split(" (").next()?;
    [
        "nso_membership_required",
        "nintendo_account_not_linked",
        "nintendo_user_not_activated",
        "nintendo_account_disabled",
        "nintendo_age_restricted",
        "nintendo_client_update_required",
        "nintendo_request_forbidden",
        "nintendo_service_closed",
        "nintendo_service_unavailable",
        "nintendo_service_maintenance",
        "splatnet_user_not_registered",
        "splatnet_version_outdated",
        "splatnet_access_restricted",
        "splatnet_service_unavailable",
        "splatnet_service_maintenance",
    ]
    .into_iter()
    .find(|known| *known == code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn missing_or_malformed_coral_status_is_never_success_or_a_credential_refresh() {
        for response in [
            json!({"result": {}}),
            json!({"status": "0", "errorMessage": "PRIVATE"}),
            json!({"status": 0, "errorMessage": "PRIVATE"}),
            json!({"status": 999999, "errorMessage": "PRIVATE"}),
        ] {
            let error = ensure_coral_success(&response).unwrap_err();
            assert!(matches!(error, CoreError::Provider(_)));
            assert!(!error.to_string().contains("PRIVATE"));
        }
    }

    #[test]
    fn known_friend_and_policy_errors_never_refresh_or_echo_remote_content() {
        for (status, code) in [
            (9400, "nintendo_request_invalid"),
            (9405, "nintendo_request_forbidden"),
            (9406, "nintendo_request_forbidden"),
            (9423, "nintendo_age_restricted"),
            (9461, "nintendo_sender_friend_limit"),
            (9462, "nintendo_receiver_friend_limit"),
            (9464, "nintendo_friend_request_pending"),
            (9467, "nintendo_already_friend"),
            (9468, "nintendo_friend_request_blocked"),
        ] {
            let error = ensure_coral_success(&json!({
                "status": status, "errorMessage": "PRIVATE"
            }))
            .unwrap_err();
            assert!(matches!(error, CoreError::Provider(_)));
            assert!(error.to_string().contains(code));
            assert!(!error.to_string().contains("PRIVATE"));
        }
        assert!(safe_activity_condition(&CoreError::Provider(
            "PRIVATE splatnet_access_restricted".into()
        ))
        .is_none());
    }

    #[test]
    fn friend_code_not_found_is_endpoint_specific() {
        let response = json!({"status":9408, "errorMessage":"PRIVATE"});
        let lookup =
            ensure_coral_success_for_endpoint(&response, Some("/v3/Friend/GetUserByFriendCode"))
                .unwrap_err();
        assert!(lookup
            .to_string()
            .contains("nintendo_friend_code_not_found"));
        assert!(!lookup.to_string().contains("PRIVATE"));

        for endpoint in [None, Some("/v4/Friend/List")] {
            let other = ensure_coral_success_for_endpoint(&response, endpoint).unwrap_err();
            assert!(other.to_string().contains("nintendo_request_failed"));
            assert!(!other.to_string().contains("nintendo_friend_code_not_found"));
        }
    }

    #[test]
    fn optional_splatnet_activity_keeps_specific_coral_policy_and_service_guidance() {
        for (status, expected) in [
            (9423, "nintendo_age_restricted"),
            (9427, "nintendo_client_update_required"),
            (9405, "nintendo_request_forbidden"),
            (9499, "nintendo_service_closed"),
            (9500, "nintendo_service_unavailable"),
            (9511, "nintendo_service_maintenance"),
        ] {
            let error = ensure_coral_success(&json!({"status":status, "errorMessage":"PRIVATE"}))
                .unwrap_err();
            assert_eq!(safe_activity_condition(&error), Some(expected), "{status}");
        }
    }

    #[test]
    fn revoked_root_guidance_survives_activity_failure_but_not_untrusted_authentication_text() {
        assert_eq!(
            safe_activity_condition(&CoreError::Authentication(
                "nintendo_sign_in_required".into()
            )),
            Some("nintendo_sign_in_required")
        );
        for message in [
            "PRIVATE nintendo_sign_in_required",
            "nintendo_sign_in_required PRIVATE",
            "splatnet_bullet_token_invalid",
        ] {
            assert_eq!(
                safe_activity_condition(&CoreError::Authentication(message.into())),
                None
            );
        }
    }
}
