# FPGA Drive NVMe Offload

Processor-free NVMe recorder for the [FPGA Drive FMC Gen4](https://docs.opsero.com/op063/datasheet/overview/)
and the [M.2 M-key Stack FMC](https://docs.opsero.com/op073/datasheet/overview/): streams data from the
FPGA fabric straight to a file on an NVMe SSD, with the AMD NVMe Host Accelerator IP and fabric logic
building and completing every NVMe command. No CPU in the data path.

This reference design is the hardware-driven counterpart of
[fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder), which records the same
fabric stream through Linux. Both are measured with the same SSDs and the same method so that the two
approaches can be compared.

Work in progress: the design is being developed on the `dev` branch and will be merged here once it has
been validated on hardware.

## License

MIT, see [LICENSE.txt](LICENSE.txt).
