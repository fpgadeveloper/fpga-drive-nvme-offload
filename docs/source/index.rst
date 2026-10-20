.. FPGA Drive NVMe Offload Recorder documentation master file.

FPGA Drive NVMe Offload Recorder
================================

This is the documentation for the FPGA Drive NVMe Offload Recorder reference design:
recording of data generated in the FPGA fabric to NVMe SSDs, and playback into the fabric,
with the NVMe commands built in the fabric and queued by the AMD NVMe Host Accelerator IP --
no CPU in the data path. For the `FPGA Drive FMC Gen4`_ and the `M.2 M-key Stack FMC`_.


.. toctree::
   :maxdepth: 2
   :caption: User Guide

   description
   requirements
   supported_carriers
   supported_ssds
   build_instructions
   architecture
   yocto
   linux_test
   filesystem
   apps
   benchmarks
   comparison
   limitations
   troubleshooting
   revision_history

.. toctree::
   :maxdepth: 2
   :caption: Reference

   register_map
   driver

.. toctree::
   :maxdepth: 2
   :caption: Customizing the design

   custom_source
   custom_sink


.. _FPGA Drive FMC Gen4: https://docs.opsero.com/op063/datasheet/overview/
.. _M.2 M-key Stack FMC: https://docs.opsero.com/op073/datasheet/overview/
