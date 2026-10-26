## Golden parity in the host

| Candidate       | Precision | Units | Checked | Token mismatches | Max abs Δp | Decision changes                                     | Load ms |
| --------------- | --------- | ----- | ------- | ---------------- | ---------- | ---------------------------------------------------- | ------- |
| System XSmall   | FP16      | all   | 12      | 0                | 0.0081     | none                                                 | 155     |
| System XSmall   | INT8      | all   | 12      | 0                | 0.0309     | synthetic:en-overlap-orders-flights-2:4: ["Flights"] | 5002    |
| System mDeBERTa | FP16      | all   | 12      | 0                | 0.0247     | none                                                 | 22352   |
| System mDeBERTa | INT8      | all   | 12      | 0                | 0.0650     | none                                                 | 404260  |
| Custom XSmall   | FP16      | all   | 72      | 0                | 0.0187     | none                                                 | 2398    |
| Custom XSmall   | INT8      | all   | 72      | 0                | 0.0370     | none                                                 | 60316   |
| Custom mDeBERTa | FP16      | all   | 72      | 0                | 0.0346     | none                                                 | 639     |
| Custom mDeBERTa | INT8      | all   | 72      | 0                | 0.1203     | none                                                 | 15176   |

## Benchmarks (3 rounds of 12 samples)

| Candidate       | Precision | Units              | Custom Categories | Passes | Pass p50 ms | Pass p95 ms | Messages/s | Peak MB | CPU mJ/pass | Main thread p95 ms | Thermal           |
| --------------- | --------- | ------------------ | ----------------- | ------ | ----------- | ----------- | ---------- | ------- | ----------- | ------------------ | ----------------- |
| System XSmall   | FP16      | all                | –                 | 36     | 13.4        | 15.3        | 71.39      | 205     | 6           | 0.01               | nominal → nominal |
| System XSmall   | INT8      | all                | –                 | 36     | 13.2        | 13.5        | 73.37      | 270     | 5           | 0.01               | nominal → nominal |
| System mDeBERTa | FP16      | all                | –                 | 36     | 765.5       | 780.2       | 1.30       | 1448    | 2608        | 0.06               | nominal → nominal |
| System mDeBERTa | INT8      | all                | –                 | 36     | 792.8       | 803.0       | 1.26       | 1986    | 2484        | 0.07               | fair → fair       |
| Custom XSmall   | FP16      | all                | 5                 | 180    | 13.3        | 13.7        | 14.39      | 317     | 5           | 0.01               | fair → fair       |
| Custom XSmall   | FP16      | all                | 20                | 720    | 13.2        | 13.5        | 3.61       | 203     | 5           | 0.01               | fair → fair       |
| Custom XSmall   | FP16      | all                | 50                | 1800   | 13.2        | 13.5        | 1.45       | 203     | 5           | 0.09               | fair → fair       |
| Custom XSmall   | INT8      | all                | 5                 | 180    | 96.1        | 100.8       | 2.05       | 388     | 328         | 0.07               | fair → fair       |
| Custom XSmall   | INT8      | all                | 20                | 720    | 96.5        | 99.7        | 0.51       | 389     | 324         | 0.06               | fair → fair       |
| Custom XSmall   | INT8      | all                | 50                | 1800   | 96.9        | 99.3        | 0.20       | 390     | 317         | 0.07               | fair → fair       |
| Custom mDeBERTa | FP16      | all                | 5                 | 180    | 26.0        | 26.7        | 7.51       | 398     | 5           | 0.09               | fair → fair       |
| Custom mDeBERTa | FP16      | all                | 20                | 720    | 26.0        | 26.6        | 1.88       | 368     | 5           | 0.08               | fair → fair       |
| Custom mDeBERTa | FP16      | all                | 50                | 1800   | 26.0        | 26.2        | 0.75       | 368     | 5           | 0.09               | fair → fair       |
| Custom mDeBERTa | INT8      | all                | 5                 | 180    | 26.1        | 26.8        | 7.47       | 298     | 5           | 0.09               | fair → fair       |
| Custom mDeBERTa | INT8      | all                | 20                | 720    | 26.1        | 26.8        | 1.87       | 299     | 5           | 0.09               | fair → fair       |
| Custom mDeBERTa | INT8      | all                | 50                | 1800   | 26.1        | 26.7        | 0.75       | 299     | 5           | 0.09               | fair → fair       |
| System XSmall   | FP16      | cpuOnly            | –                 | 36     | 29.4        | 30.4        | 33.14      | 361     | 124         | 0.01               | fair → fair       |
| System XSmall   | FP16      | cpuAndGPU          | –                 | 36     | 6.0         | 6.9         | 20.30      | 275     | 45          | 0.07               | fair → fair       |
| System XSmall   | FP16      | cpuAndNeuralEngine | –                 | 36     | 15.1        | 19.0        | 64.74      | 228     | 12          | 0.02               | fair → fair       |

## Compute plans

| Candidate       | Precision | Units              | Preferred device (ops)          | No Neural Engine (ops)                                                                                       |
| --------------- | --------- | ------------------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| System XSmall   | FP16      | all                | cpu 1, gpu 15, neuralEngine 485 | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| System XSmall   | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| System mDeBERTa | FP16      | all                | cpu 88, neuralEngine 413        | ios18.cast 3, ios18.gather 1, ios18.gather_along_axis 24, select 12                                          |
| System mDeBERTa | FP16      | cpuAndNeuralEngine | cpu 88, neuralEngine 413        | ios18.cast 3, ios18.gather 1, ios18.gather_along_axis 24, select 12                                          |
| Custom XSmall   | FP16      | all                | cpu 1, gpu 15, neuralEngine 485 | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom XSmall   | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom mDeBERTa | FP16      | all                | cpu 1, gpu 15, neuralEngine 485 | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom mDeBERTa | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
