## Golden parity in the host

| Candidate       | Precision | Units | Checked | Token mismatches | Max abs Δp | Decision changes                                     | Load ms |
| --------------- | --------- | ----- | ------- | ---------------- | ---------- | ---------------------------------------------------- | ------- |
| System XSmall   | FP16      | all   | 12      | 0                | 0.0089     | none                                                 | 1769    |
| System XSmall   | INT8      | all   | 12      | 0                | 0.0312     | synthetic:en-overlap-orders-flights-2:4: ["Flights"] | 5286    |
| System mDeBERTa | FP16      | all   | 12      | 0                | 0.0247     | none                                                 | 11838   |
| System mDeBERTa | INT8      | all   | 12      | 0                | 0.0650     | none                                                 | 1769115 |
| Custom XSmall   | FP16      | all   | 72      | 0                | 0.0232     | none                                                 | 9469    |
| Custom XSmall   | INT8      | all   | 72      | 0                | 0.0408     | none                                                 | 27440   |
| Custom mDeBERTa | FP16      | all   | 72      | 0                | 0.0346     | none                                                 | 17475   |
| Custom mDeBERTa | INT8      | all   | 72      | 0                | 0.1203     | none                                                 | 79566   |

## Benchmarks (3 rounds of 12 samples)

| Candidate       | Precision | Units              | Custom Categories | Passes | Pass p50 ms | Pass p95 ms | Messages/s | Peak MB | CPU mJ/pass | Main thread p95 ms | Thermal           |
| --------------- | --------- | ------------------ | ----------------- | ------ | ----------- | ----------- | ---------- | ------- | ----------- | ------------------ | ----------------- |
| System XSmall   | FP16      | all                | –                 | 36     | 13.3        | 13.7        | 72.17      | 348     | 6           | 0.01               | nominal → nominal |
| System XSmall   | INT8      | all                | –                 | 36     | 13.1        | 13.6        | 72.36      | 523     | 6           | 0.02               | nominal → nominal |
| System mDeBERTa | FP16      | all                | –                 | 36     | 3097.5      | 3151.3      | 0.33       | 2161    | 391         | 0.20               | nominal → nominal |
| System mDeBERTa | INT8      | all                | –                 | 36     | 3173.3      | 3202.1      | 0.32       | 2074    | 382         | 0.07               | nominal → nominal |
| Custom XSmall   | FP16      | all                | 5                 | 180    | 16.4        | 17.5        | 9.47       | 1182    | 1           | 0.05               | nominal → nominal |
| Custom XSmall   | FP16      | all                | 20                | 720    | 16.4        | 17.6        | 2.39       | 1001    | 1           | 0.20               | nominal → nominal |
| Custom XSmall   | FP16      | all                | 50                | 1800   | 16.4        | 17.5        | 0.94       | 650     | 1           | 0.16               | nominal → nominal |
| Custom XSmall   | INT8      | all                | 5                 | 180    | 17.6        | 19.1        | 8.90       | 564     | 1           | 0.13               | nominal → nominal |
| Custom XSmall   | INT8      | all                | 20                | 720    | 17.7        | 19.3        | 2.21       | 564     | 1           | 0.24               | nominal → nominal |
| Custom XSmall   | INT8      | all                | 50                | 1800   | 17.7        | 19.3        | 0.88       | 564     | 1           | 0.20               | nominal → nominal |
| Custom mDeBERTa | FP16      | all                | 5                 | 180    | 31.5        | 32.1        | 5.57       | 927     | 1           | 0.12               | nominal → nominal |
| Custom mDeBERTa | FP16      | all                | 20                | 720    | 31.5        | 32.1        | 1.39       | 928     | 1           | 0.20               | nominal → nominal |
| Custom mDeBERTa | FP16      | all                | 50                | 1800   | 31.5        | 32.1        | 0.56       | 434     | 1           | 0.06               | nominal → nominal |
| Custom mDeBERTa | INT8      | all                | 5                 | 180    | 31.3        | 31.8        | 5.61       | 1676    | 1           | 0.05               | nominal → nominal |
| Custom mDeBERTa | INT8      | all                | 20                | 720    | 31.4        | 32.0        | 1.39       | 1676    | 1           | 0.08               | nominal → nominal |
| Custom mDeBERTa | INT8      | all                | 50                | 1800   | 31.4        | 32.0        | 0.56       | 339     | 1           | 0.18               | nominal → nominal |
| System XSmall   | FP16      | cpuOnly            | –                 | 36     | 172.3       | 182.3       | 5.75       | 564     | 21          | 0.21               | nominal → nominal |
| System XSmall   | FP16      | cpuAndGPU          | –                 | 36     | 12.5        | 14.0        | 11.15      | 728     | 7           | 0.08               | nominal → nominal |
| System XSmall   | FP16      | cpuAndNeuralEngine | –                 | 36     | 14.5        | 18.2        | 51.72      | 750     | 2           | 0.05               | nominal → nominal |

## Compute plans

| Candidate       | Precision | Units              | Preferred device (ops)          | No Neural Engine (ops)                                                                                       |
| --------------- | --------- | ------------------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| System XSmall   | FP16      | all                | gpu 45, neuralEngine 456        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| System XSmall   | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| System mDeBERTa | FP16      | all                | cpu 88, neuralEngine 413        | ios18.cast 3, ios18.gather 1, ios18.gather_along_axis 24, select 12                                          |
| System mDeBERTa | FP16      | cpuAndNeuralEngine | cpu 88, neuralEngine 413        | ios18.cast 3, ios18.gather 1, ios18.gather_along_axis 24, select 12                                          |
| Custom XSmall   | FP16      | all                | gpu 45, neuralEngine 456        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom XSmall   | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom mDeBERTa | FP16      | all                | cpu 1, gpu 15, neuralEngine 485 | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
| Custom mDeBERTa | FP16      | cpuAndNeuralEngine | cpu 16, neuralEngine 485        | ios18.add 1, ios18.cast 4, ios18.expand_dims 4, ios18.gather 1, ios18.greater_equal 1, ios18.mul 1, select 1 |
