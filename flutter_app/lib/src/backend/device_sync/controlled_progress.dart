part of 'startup_lifecycle.dart';

/// Advances only steps covered by local consent or authenticated phone consent.
/// Rust remains the sole transport pump and authority for durable completion.
extension _DeviceSessionProgress on DeviceSyncSession {
  Future<void> _advance(read.EndpointView? view) async {
    if (closed || busy || _advanceBlocked || view == null) return;
    final coordinator = _service._owner._coordinator!;
    Future<void> advance(Future<void> Function() action) async {
      await _act(action);
      if (_issue == read.ReadError.busy) _setIssue(null);
    }

    try {
      if (view.phoneControlled &&
          view.stage == driver.State.awaitingAccountConsent &&
          view.accountsConsentAuthorized &&
          !accountsAuthorized) {
        await advance(() async {
          if (view.source == true) {
            await coordinator.authorizeSource(_endpoint, authorized: true);
          } else if (view.source == false) {
            await coordinator.authorizeTarget(_endpoint, authorized: true);
          } else {
            throw AccountPreviewChanged();
          }
          _accountConsent = true;
        });
      } else if (view.phoneControlled &&
          view.stage == driver.State.awaitingApproval &&
          view.source == false &&
          accountsAuthorized &&
          !_approved) {
        await advance(() async {
          final account = _accountPreview ??= await coordinator.preview(
            _endpoint,
          );
          if (_publishedAccountPreviewBinding != account.binding) {
            final change = account.change;
            await _command(
              () => native.deviceSyncPublishAccountPreview(
                endpoint: _endpoint,
                binding: account.binding,
                added: BigInt.from(change.added.length),
                replaced: BigInt.from(change.replaced.length),
                removed: BigInt.from(change.removed.length),
                kept: BigInt.from(
                  change.before.payload.accounts.length -
                      change.replaced.length -
                      change.removed.length,
                ),
              ),
            );
            _publishedAccountPreviewBinding = account.binding;
          }
          if (view.previewApproved) {
            await coordinator.approve(account, authorized: true);
            _approved = true;
          }
        });
      } else if (view.stage == driver.State.awaitingTargetAccountFinal &&
          accountsAuthorized &&
          _approved &&
          !_targetFinal) {
        await advance(() async {
          await coordinator.authorizeFinalTarget(_endpoint);
          _targetFinal = true;
        });
      } else if (view.stage == driver.State.awaitingAccountFinal &&
          accountsAuthorized &&
          !_sourceFinal) {
        await advance(() async {
          await coordinator.authorizeFinalSource(_endpoint);
          _sourceFinal = true;
        });
      } else if (view.stage == driver.State.awaitingExternal &&
          accountsAuthorized &&
          _approved &&
          _targetFinal &&
          !_applied) {
        await advance(() async {
          final result = await coordinator.applyPending(_endpoint);
          _applied = result.finalized;
        });
      } else if (view.terminal && !view.cleanupPending && !_sourceReleased) {
        await advance(() async {
          await coordinator.releaseSource(_endpoint);
          _sourceReleased = true;
        });
      }
    } on DeviceSyncBusy {
      // Only the original coordinator's known unexecuted admission is resumed.
      _setIssue(read.ReadError.busy);
    } catch (failure) {
      _advanceBlocked = true;
      _setIssue(switch (failure) {
        AccountPreviewChanged() => read.ReadError.previewChanged,
        AccountRecoveryRequired() => read.ReadError.recoveryRequired,
        DeviceCommandError(:final code) => code,
        _ => read.ReadError.internal,
      });
      _service._recordFailure(failure);
    }
    _publish();
  }
}
