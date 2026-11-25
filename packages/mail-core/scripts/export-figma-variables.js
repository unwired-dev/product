(async () => {
  // Exports every local variable of the Unwired Mail — Design file with its value in each mode, as
  // test/figma-variables.json records them. Run it through the Figma MCP server's `use_figma` tool
  // on file d1mHEaUNmnF7YUw6QwIs0T, with `return ` followed by this file as the code, and write the
  // result to test/figma-variables.json. It only reads. The Plugin API exposes no file version, and
  // use_figma cannot save one, so the snapshot is stamped with the time of the export instead.
  const rounded = (value) => Math.round(value * 1000) / 1000;
  const valueOf = (value) => {
    if (typeof value === 'number') {
      return rounded(value);
    }
    const rgb = [value.r, value.g, value.b].map((part) =>
      Math.round(part * 255),
    );
    return value.a < 1
      ? `rgba(${rgb.join(', ')}, ${rounded(value.a)})`
      : `#${rgb.map((part) => part.toString(16).padStart(2, '0').toUpperCase()).join('')}`;
  };
  const collections = [];
  for (const collection of await figma.variables.getLocalVariableCollectionsAsync()) {
    const variables = await Promise.all(
      collection.variableIds.map((id) =>
        figma.variables.getVariableByIdAsync(id),
      ),
    );
    variables.sort((left, right) => (left.name < right.name ? -1 : 1));
    collections.push({
      name: collection.name,
      modes: collection.modes.map((mode) => mode.name),
      variables: Object.fromEntries(
        variables.map((variable) => [
          variable.name,
          Object.fromEntries(
            collection.modes.map((mode) => [
              mode.name,
              valueOf(variable.valuesByMode[mode.modeId]),
            ]),
          ),
        ]),
      ),
    });
  }
  return {
    fileKey: figma.fileKey,
    exportedAt: new Date().toISOString(),
    collections,
  };
})();
