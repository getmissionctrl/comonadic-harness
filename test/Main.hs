module Main (main) where

import Test.Hspec (hspec)
import qualified LawsSpec
import qualified PerfSpec
import qualified HostileSpec
import qualified ProviderSpec
import qualified ToolsSpec
import qualified AgUiEventSpec
import qualified AgUiTranslateSpec
import qualified AgUiSinkSpec
import qualified AgUiHumanEnvSpec
import qualified AgUiServerSpec

main :: IO ()
main = hspec $ do
  LawsSpec.spec
  PerfSpec.spec
  HostileSpec.spec
  ProviderSpec.spec
  ToolsSpec.spec
  AgUiEventSpec.spec
  AgUiTranslateSpec.spec
  AgUiSinkSpec.spec
  AgUiHumanEnvSpec.spec
  AgUiServerSpec.spec
