Future<void> restartApplication({
  required Future<void> Function() startNewInstance,
  required Future<void> Function() quitCurrentInstance,
}) async {
  await startNewInstance();
  await quitCurrentInstance();
}
