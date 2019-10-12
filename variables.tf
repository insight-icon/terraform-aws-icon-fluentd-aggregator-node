variable "name" {
  type = "string"
}
variable "environment" {
  description = "The environment that generally corresponds to the account you are deploying into."
}

variable "tags" {
  description = "Tags that are appended"
  type        = map(string)
}

variable "instance_type" {}
variable "root_volume_size" {}
variable "volume_path" {}

//variable "local_private_key" {} # TODO Only needed for remote calls but commented out now

variable "azs" {
  description = "The availablity zones to deploy each ebs volume into."
  type        = list(string)
}

variable "key_name" {}

variable "security_groups" {
  type = list(string)
}
variable "subnet_id" {}

variable "user_data_script" {
  type = string
  default = "user_data_ubuntu_ebs.sh"
}

variable "root_domain_name" {}
variable "zone_id" {}