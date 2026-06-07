## Test RF3
```
# install conda/mamba
wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
bash Miniforge3-Linux-x86_64.sh
source /home/ubuntu/.bashrc
conda install -n base -c conda-forge mamba -y
mamba --version
# create env rfd3
mamba create -n rfd3 python=3.12 -y
mamba activate rfd3
pip install "rc-foundry[rfd3]"
# setup
mkdir -p /mnt/sdd/rfd3_ch
sudo chown $USER:$USER /mnt/sdd/rfd3_checkpoints
# install checkpoints
foundry install rfd3 --checkpoint-dir /mnt/sdd/rfd3_ch
python -c "import torch; print(torch.cuda.is_available())"
# get more info on release gpu
cat /etc/os-release
# check install
rfd3 --help
# link checkpoints
ln -s /mnt/sdd/rfd3_ch/rfd3_latest.ckpt       ~/.foundry/checkpoints/rfd3_latest.ckpt
ll ~/.foundry/checkpoints/rfd3_latest.ckpt

git clone https://github.com/RosettaCommons/foundry.git
rfd3 design   out_dir=/mnt/sdd/rfd3_test   inputs=/mnt/sdd/foundry/models/rfd3/docs/examples/demo.json   skip_existing=False   dump_trajectories=True   prevalidate_inputs=True
```
